defmodule MetadataApp.Purga.Releases do
  @moduledoc """
  Los paquetes publicados en GitHub Releases (`bc-*` y `retirado-*`) vistos
  como datos (SPEC-ARQ-3009202601, design §4.1): qué artefactos hay, qué
  archivos son de cada uno y el plan para retirar uno.

  Las funciones que llaman a `gh` reciben `gh`:
  `fn args -> {:ok, {salida, status}} | {:error, mensaje} end`, con
  default a `gh/1`. Solo se cambia en pruebas.
  """

  alias MetadataApp.Purga.Unidad

  @asset "bundle.tar.gz"
  @dir_catalogos "lib/metadata_app/meta_business_process/catalogos/"
  @dir_reglas "lib/metadata_app/meta_business_process/reglas/"
  @dir_meta "priv/repo/catalogos/"
  @dir_migraciones "priv/repo/migrations/"

  @doc "Ejecuta el CLI `gh` en el directorio del repo."
  def gh(args) do
    {:ok, System.cmd("gh", args, stderr_to_stdout: true)}
  rescue
    e in ErlangError ->
      {:error,
       "No se pudo ejecutar \"gh\" -- ¿está instalado y en el PATH? (#{Exception.message(e)})"}
  end

  ## Lectura de GitHub

  @doc """
  Todos los paquetes `bc-*` y `retirado-*` con sus archivos en memoria:
  `{:ok, %{tag => %{ruta => contenido}}}` | `{:error, mensaje}`.
  Cada asset se descarga una sola vez a `cache_dir` (por id: re-subir un
  paquete crea un asset con id nuevo).
  """
  def leer(gh \\ &gh/1, cache_dir \\ cache_dir()) do
    with {:ok, releases} <- listar(gh) do
      File.mkdir_p!(cache_dir)

      Enum.reduce_while(releases, {:ok, %{}}, fn %{tag: tag, asset_id: id}, {:ok, acc} ->
        case descargar(tag, id, gh, cache_dir) do
          {:ok, path} -> {:cont, {:ok, Map.put(acc, tag, extraer(path))}}
          error -> {:halt, error}
        end
      end)
    end
  end

  def cache_dir, do: Path.join(System.tmp_dir!(), "metadata_purga_paquetes")

  @doc false
  def listar(gh) do
    jq =
      ".[] | select(.tag_name | startswith(\"bc-\") or startswith(\"retirado-\"))" <>
        " | {tag: .tag_name, asset_id: ([.assets[] | select(.name == \"#{@asset}\") | .id] | first)}"

    case gh.(["api", "--paginate", "repos/{owner}/{repo}/releases?per_page=100", "--jq", jq]) do
      {:ok, {salida, 0}} ->
        releases =
          salida
          |> String.split(~r/\r?\n/, trim: true)
          |> Enum.map(&Jason.decode!/1)
          |> Enum.reject(&is_nil(&1["asset_id"]))
          |> Enum.map(&%{tag: &1["tag"], asset_id: &1["asset_id"]})

        {:ok, releases}

      {:ok, {salida, status}} ->
        {:error, "gh api releases falló (status #{status}): #{salida}"}

      error ->
        error
    end
  end

  defp descargar(tag, asset_id, gh, cache_dir) do
    path = Path.join(cache_dir, "#{asset_id}.tar.gz")

    if File.exists?(path) do
      {:ok, path}
    else
      case gh.(["release", "download", tag, "--pattern", @asset, "--output", path, "--clobber"]) do
        {:ok, {_, 0}} ->
          {:ok, path}

        {:ok, {salida, status}} ->
          {:error, "No se pudo descargar el paquete #{tag} (status #{status}): #{salida}"}

        error ->
          error
      end
    end
  end

  @doc "Archivos de un `.tar.gz` como `%{ruta => contenido}`."
  def extraer(path) do
    {:ok, archivos} = :erl_tar.extract(String.to_charlist(path), [:memory, :compressed])
    Map.new(archivos, fn {ruta, contenido} -> {List.to_string(ruta), contenido} end)
  end

  @doc "Escribe `archivos` como `<dir>/bundle.tar.gz` y devuelve la ruta."
  def empaquetar(archivos, dir) do
    File.mkdir_p!(dir)
    path = Path.join(dir, @asset)

    entradas =
      archivos
      |> Enum.sort()
      |> Enum.map(fn {ruta, contenido} -> {String.to_charlist(ruta), contenido} end)

    :ok = :erl_tar.create(String.to_charlist(path), entradas, [:compressed])
    path
  end

  ## Datos puros

  @doc """
  Headers publicados, armados con los `.meta.json` de todos los paquetes,
  en la forma que usa `Purga.Unidad` (`id` = nombre).
  """
  def headers(paquetes) do
    paquetes
    |> Map.values()
    |> Enum.flat_map(&Map.to_list/1)
    |> Enum.flat_map(fn {ruta, contenido} ->
      with true <- String.starts_with?(ruta, @dir_meta) and String.ends_with?(ruta, ".meta.json"),
           {:ok, %{"schema_context_name" => nombre} = meta} <- Jason.decode(contenido) do
        [
          %{
            id: nombre,
            nombre: nombre,
            encabezado_id: meta["schema_encabezado_catalogo"],
            tipo: meta["schema_context_type"] || 1
          }
        ]
      else
        _ -> []
      end
    end)
    |> Enum.uniq_by(& &1.nombre)
  end

  @doc """
  Nombres de lápidas: paquetes `bc-<nombre>` (`pty_*`) sin el `.meta.json`
  de `<nombre>` en ningún paquete. Los dejó `mix motor.despublicar`: solo
  traen migraciones (la de `eliminar_` incluida).
  """
  def lapidas(paquetes) do
    con_meta = MapSet.new(headers(paquetes), & &1.nombre)

    for {tag, _} <- paquetes,
        nombre = nombre_de_tag(tag),
        Unidad.nombre_valido?(nombre),
        not MapSet.member?(con_meta, nombre),
        uniq: true do
      nombre
    end
    |> Enum.sort()
  end

  # "bc-X" y "retirado-X" -> "X"; cualquier otro tag -> "" (no válido).
  defp nombre_de_tag("bc-" <> nombre), do: nombre
  defp nombre_de_tag("retirado-" <> nombre), do: nombre
  defp nombre_de_tag(_), do: ""

  @doc """
  Artefactos retirables publicados (R2): catálogos con su unidad,
  consultas, consultas SQL (R15) y lápidas. `[%{nombre, tipo: :catalogo | :consulta | :consulta_sql | :lapida, tablas, paquetes, retirado}]`.
  """
  def artefactos(paquetes) do
    catalogos =
      for u <- Unidad.unidades_de(headers(paquetes)) do
        %{nombre: u.maestro, tipo: Unidad.nombre_tipo(u.tipo), tablas: u.tablas}
      end

    lapidas = for n <- lapidas(paquetes), do: %{nombre: n, tipo: :lapida, tablas: [n]}
    universo = universo(paquetes)

    (catalogos ++ lapidas)
    |> Enum.map(fn a ->
      propios = ["bc-#{a.nombre}", "retirado-#{a.nombre}"]

      # Una lápida es entera de X: sus paquetes propios cuentan completos.
      rutas_por_tag =
        for {tag, archivos} <- paquetes, into: %{} do
          rutas =
            if a.tipo == :lapida and tag in propios,
              do: Map.keys(archivos),
              else: archivos_de(a.tablas, Map.keys(archivos), universo)

          {tag, rutas}
        end

      tags =
        for {tag, rutas} <- rutas_por_tag, String.starts_with?(tag, "bc-"), rutas != [], do: tag

      a
      |> Map.put(:paquetes, Enum.sort(tags))
      |> Map.put(:retirado, Map.has_key?(paquetes, "retirado-#{a.nombre}"))
      |> Map.put(
        :versiones,
        rutas_por_tag |> Map.values() |> List.flatten() |> Map.new(&{&1, ""}) |> versiones()
      )
    end)
    |> Enum.sort_by(& &1.nombre)
  end

  @doc "Todos los nombres de tabla conocidos en los paquetes (catálogos y lápidas)."
  def universo(paquetes) do
    nombres = Enum.map(headers(paquetes), & &1.nombre)
    etiquetas = for {tag, _} <- paquetes, n = nombre_de_tag(tag), Unidad.nombre_valido?(n), do: n
    Enum.uniq(nombres ++ etiquetas)
  end

  @doc "Las rutas de `rutas` que pertenecen a `tablas`."
  def archivos_de(tablas, rutas, universo) do
    propias = MapSet.new(tablas)

    Enum.filter(rutas, fn ruta ->
      cond do
        String.starts_with?(ruta, @dir_migraciones) ->
          Unidad.migraciones(tablas, [Path.basename(ruta)], universo) != []

        String.starts_with?(ruta, @dir_catalogos) ->
          MapSet.member?(propias, Path.basename(ruta, ".ex"))

        String.starts_with?(ruta, @dir_meta) ->
          MapSet.member?(propias, ruta |> Path.basename() |> String.split(".") |> hd())

        String.starts_with?(ruta, @dir_reglas) ->
          MapSet.member?(
            propias,
            ruta |> String.replace_prefix(@dir_reglas, "") |> String.split("/") |> hd()
          )

        true ->
          false
      end
    end)
  end

  @doc """
  Plan para retirar `maestro` (design §4.1). No toca GitHub.

  `{:ok, plan}` | `{:error, mensaje}`. `plan`:
  - `tablas`: las del artefacto, detalles primero.
  - `inventario`: `%{ruta => contenido}` para `retirado-<maestro>`.
  - `modificados`: `[%{tag, archivos}]`, paquetes `bc-*` que se re-suben sin X.
  - `bc_propio`: `:no_existe` | `:borrar` | `{:conservar, archivos, catalogos}`.
  - `nada_que_hacer`: ningún `bc-*` trae archivos de X.
  """
  def plan_retiro(maestro, paquetes) do
    headers = headers(paquetes)
    universo = universo(paquetes)
    propio = "bc-#{maestro}"
    lapida? = maestro in lapidas(paquetes)

    tablas_o_error = if lapida?, do: {:ok, [maestro]}, else: tablas_publicadas(maestro, headers)

    with {:ok, tablas} <- tablas_o_error do
      # Una lápida es entera de X: su paquete propio sale completo.
      quitar =
        for {tag, archivos} <- paquetes, String.starts_with?(tag, "bc-"), into: %{} do
          rutas =
            if lapida? and tag == propio,
              do: Map.keys(archivos),
              else: archivos_de(tablas, Map.keys(archivos), universo)

          {tag, rutas}
        end

      con_x = for {tag, rutas} <- quitar, rutas != [], do: tag

      modificados =
        for tag <- con_x, tag != propio do
          %{tag: tag, archivos: Map.drop(paquetes[tag], quitar[tag])}
        end

      case Enum.find(modificados, &(&1.archivos == %{})) do
        %{tag: tag} ->
          {:error,
           "El paquete #{tag} solo trae #{maestro}: al sacarlo quedaría vacío. Retira #{String.replace_prefix(tag, "bc-", "")} primero."}

        nil ->
          inventario =
            Enum.reduce(con_x, Map.get(paquetes, "retirado-#{maestro}", %{}), fn tag, acc ->
              Map.merge(acc, Map.take(paquetes[tag], quitar[tag]))
            end)

          {:ok,
           %{
             maestro: maestro,
             tipo: if(lapida?, do: :lapida, else: tipo_de(maestro, headers)),
             tablas: tablas,
             inventario: inventario,
             modificados: modificados,
             bc_propio: bc_propio(propio, paquetes, quitar, modificados),
             nada_que_hacer: con_x == []
           }}
      end
    end
  end

  defp tipo_de(nombre, headers) do
    headers |> Enum.find(&(&1.nombre == nombre)) |> Map.get(:tipo) |> Unidad.nombre_tipo()
  end

  defp tablas_publicadas(maestro, headers) do
    case Unidad.tablas_de(maestro, headers) do
      {:ok, tablas} ->
        {:ok, tablas}

      {:error, :no_existe} ->
        {:error, "#{maestro} no aparece en ningún paquete publicado."}

      {:error, {:es_detalle, raiz}} ->
        {:error, "#{maestro} es detalle de #{raiz}: se retira junto con su maestro."}

      {:error, {:no_purgable, _tipo}} ->
        {:error, "#{maestro} es una carpeta de navegación: las carpetas no se retiran."}

      {:error, :nombre_invalido} ->
        {:error, "Solo se retiran artefactos pty_*."}
    end
  end

  # Lo que queda en bc-<maestro> después de sacar X son los catálogos que
  # referenciaba. Si alguno solo viaja ahí, el paquete se conserva con
  # ellos para no sacarlos de los builds.
  defp bc_propio(propio, paquetes, quitar, modificados) do
    case Map.fetch(paquetes, propio) do
      :error ->
        :no_existe

      {:ok, archivos} ->
        restantes = Map.drop(archivos, quitar[propio])

        otros =
          paquetes
          |> Enum.filter(fn {tag, _} -> String.starts_with?(tag, "bc-") and tag != propio end)
          |> Map.new()
          |> Map.merge(Map.new(modificados, &{&1.tag, &1.archivos}))
          |> headers()
          |> MapSet.new(& &1.nombre)

        huerfanos =
          restantes
          |> headers_de_archivos()
          |> Enum.reject(&MapSet.member?(otros, &1))

        if huerfanos == [], do: :borrar, else: {:conservar, restantes, huerfanos}
    end
  end

  defp headers_de_archivos(archivos), do: %{"x" => archivos} |> headers() |> Enum.map(& &1.nombre)

  @doc "Versiones de migración del inventario (para limpiar la tabla de migraciones en cada destino)."
  def versiones(inventario) do
    for ruta <- Map.keys(inventario), String.starts_with?(ruta, @dir_migraciones), uniq: true do
      Unidad.version(ruta)
    end
    |> Enum.sort()
  end
end
