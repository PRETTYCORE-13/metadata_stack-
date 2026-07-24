defmodule MetadataApp.MetaPublicador do
  @moduledoc """
  Arma y despliega un paquete de BCs (schema+migraciones+autómata+reglas)
  directo a producción — lógica compartida entre `mix motor.publicar`
  (CLI) y el wizard de publicación (LiveView, en construcción), extraída
  con el mismo criterio que MetaImportExport: sin depender de Mix para
  que cualquier caller la pueda usar, devolviendo resultados en vez de
  imprimir o abortar directo.

  Acepta una LISTA de catálogos raíz (no solo uno) — el wizard permite
  seleccionar varios BC a la vez; el paquete final es la unión de sus
  cierres de dependencias, ya en orden (ver
  MetaSchemaContext.calcular_paquete_publicacion/1).
  """

  alias MetadataApp.MetaEstadosAdmin
  alias MetadataApp.BusinessProcessBuilder.MetaSchemaContext

  @doc """
  Valida uno o más catálogos raíz y calcula el paquete completo a publicar.
  {:ok, %{catalogos: [...], problemas: [...]}} | {:error, mensaje}
  """
  def validar(nombres_raiz) when is_list(nombres_raiz) do
    resultados = Enum.map(nombres_raiz, &validar_uno/1)

    case Enum.find(resultados, &match?({:error, _}, &1)) do
      {:error, _} = error ->
        error

      nil ->
        problemas = Enum.flat_map(resultados, fn {:ok, r} -> r.problemas end)
        valido? = Enum.all?(resultados, fn {:ok, r} -> r.valido? end)

        if valido? do
          {:ok, %{catalogos: MetaSchemaContext.calcular_paquete_publicacion(nombres_raiz), problemas: problemas}}
        else
          {:error, "hay errores estructurales, corregilos antes de publicar"}
        end
    end
  end

  defp validar_uno(nombre) do
    case MetaSchemaContext.obtener_header_por_nombre(nombre) do
      nil ->
        {:error, "\"#{nombre}\" no existe."}

      _header ->
        case MetaEstadosAdmin.validar_motor(nombre) do
          {:error, motivo} -> {:error, "#{nombre}: #{motivo}"}
          {:ok, %{problemas: problemas, valido?: valido?}} -> {:ok, %{problemas: problemas, valido?: valido?}}
        end
    end
  end

  @doc "Arma el .tar.gz de un paquete ya calculado (lista de nombres, ya en orden). {:ok, path} | {:error, mensaje}"
  def armar_bundle(catalogos) do
    nombre_archivo = "bc-bundle-#{System.unique_integer([:positive])}.tar.gz"
    rutas = Enum.flat_map(catalogos, &rutas_de/1)

    if rutas == [] do
      {:error, "Ningún archivo encontrado para #{inspect(catalogos)} — ¿ya corriste \"mix gen.catalogos\"?"}
    else
      # El archivo de salida se escribe con un nombre relativo, en el cwd
      # actual (la raíz del proyecto) -- nunca con una ruta absoluta tipo
      # "C:\...". En Windows, una letra de unidad en el nombre del archivo
      # hace que tar la interprete como un destino REMOTO ("usuario@host:
      # ruta") y falle con "Cannot connect to C:" -- la bandera
      # "--force-local" evita eso, pero no todos los "tar.exe" la soportan
      # (el nativo de Windows que resuelve "mix phx.server" NO, a
      # diferencia del que trae Git Bash) -- más simple y portable evitar
      # el problema de raíz: nunca pasarle a tar una ruta con ":".
      # File.rename!/2 después es una operación normal de Elixir, no de
      # tar, así que mueve el archivo al temp dir sin ningún problema.
      case System.cmd("tar", ["-czf", nombre_archivo | rutas], stderr_to_stdout: true) do
        {_salida, 0} ->
          destino = Path.join(System.tmp_dir!(), nombre_archivo)
          File.rename!(nombre_archivo, destino)
          {:ok, destino}

        {salida, status} ->
          File.rm(nombre_archivo)
          {:error, "tar falló (status #{status}):\n#{salida}"}
      end
    end
  end

  defp rutas_de(catalogo) do
    schema = Path.join(["lib", "metadata_app", "meta_business_process", "catalogos", "#{catalogo}.ex"])
    migraciones = Path.wildcard("priv/repo/migrations/*#{catalogo}*.exs")
    meta = "priv/repo/catalogos/#{catalogo}.meta.json"
    motor = "priv/repo/catalogos/#{catalogo}.motor.json"
    reglas = Path.join(["lib", "metadata_app", "meta_business_process", "reglas", catalogo])

    ([schema, meta, motor] ++ migraciones ++ [reglas])
    |> Enum.filter(&File.exists?/1)
  end

  def tamanio_legible(path) do
    kb = File.stat!(path).size / 1024
    "#{Float.round(kb, 1)} KB"
  end

  @doc """
  Sube el bundle ya armado como asset a un GitHub Release por cada
  catálogo RAÍZ seleccionado (tag `bc-<catalogo>`, pisando el asset
  anterior con `--clobber`) — el Release mismo ES el manifest de "este
  catálogo debe quedar siempre vivo": no hay ningún archivo de texto
  aparte que mantener sincronizado ni commitear. `ci.yml`, en cada deploy
  normal del BPB, va a listar los releases `bc-*`, bajar cada bundle y
  reconstruir la imagen con todos adentro — así un deploy normal deja de
  "olvidar" los BCs ya publicados (ver docs/roadmap.md, CD automático).

  No borra `bundle_path` — lo sigue necesitando `disparar_deploy/2`
  después. {:ok, [tags]} | {:error, mensaje}
  """
  def persistir_bundle(nombres_raiz, bundle_path) do
    nombres_raiz
    |> Enum.reduce_while({:ok, []}, fn nombre, {:ok, acc} ->
      tag = "bc-#{nombre}"
      asegurar_release(tag, nombre)

      # "local_path#nombre_remoto": sin esto, cada publicación sube el
      # asset con el nombre de archivo temporal de armar_bundle/1 (único
      # por corrida, ej. "bc-bundle-1541.tar.gz") -- "--clobber" solo
      # reemplaza un asset con el MISMO nombre, así que cada publicación
      # se iba ACUMULANDO como un asset nuevo en vez de reemplazar el
      # anterior (encontrado real: ci.yml empezó a fallar con "unable to
      # write more than one asset" en cuanto hubo una segunda publicación).
      # Con un nombre remoto fijo, "--clobber" reemplaza siempre el mismo
      # asset -- el release nunca acumula más de uno.
      case System.cmd("gh", ["release", "upload", tag, "#{bundle_path}#bundle.tar.gz", "--clobber"], stderr_to_stdout: true) do
        {_salida, 0} -> {:cont, {:ok, [tag | acc]}}
        {salida, status} -> {:halt, {:error, "gh release upload #{tag} falló (status #{status}):\n#{salida}"}}
      end
    end)
    |> case do
      {:ok, tags} -> {:ok, Enum.reverse(tags)}
      error -> error
    end
  end

  defp asegurar_release(tag, nombre) do
    case System.cmd("gh", ["release", "view", tag], stderr_to_stdout: true) do
      {_salida, 0} ->
        :ok

      {_salida, _status} ->
        System.cmd(
          "gh",
          ["release", "create", tag, "--title", nombre, "--notes", "Bundle de #{nombre}, publicado por motor.publicar / el wizard de BC List."],
          stderr_to_stdout: true
        )

        :ok
    end
  end

  @doc """
  Dispara bc-deploy.yml con el bundle ya armado. `nombres_raiz` es solo
  para la etiqueta legible del run (image tag / mensaje) — el contenido
  real del bundle ya tiene todo el paquete completo adentro.
  {:ok, mensaje} | {:error, mensaje}
  """
  def disparar_deploy(nombres_raiz, bundle_path) do
    b64_path = bundle_path <> ".b64"
    File.write!(b64_path, Base.encode64(File.read!(bundle_path)))

    # "-" y no "+"/"," -- esto termina en un tag Docker (bc-<etiqueta>-<run>,
    # ver bc-deploy.yml), y el set de caracteres válido para un tag no
    # incluye "+" ni ",". Los nombres de catálogo ya usan "_", así que "-"
    # como separador no genera ambigüedad real para un humano leyendo el tag.
    etiqueta = Enum.join(nombres_raiz, "-")

    # El bundle viaja en base64 como archivo (@ruta), no como argumento de
    # línea de comandos ni por stdin -- un bundle de varios catálogos con
    # varias reglas puede superar el límite práctico de un solo argumento,
    # y System.cmd/3 no tiene forma de pasar stdin. "gh workflow run" lee
    # "-F campo=@archivo" como el CONTENIDO de ese archivo (mismo mecanismo
    # que "gh api", ver "gh help api").
    args = [
      "workflow",
      "run",
      "bc-deploy.yml",
      "-f",
      "catalogo=#{etiqueta}",
      "-F",
      "bundle_b64=@#{b64_path}"
    ]

    resultado = System.cmd("gh", args, stderr_to_stdout: true)
    File.rm(bundle_path)
    File.rm(b64_path)

    case resultado do
      {salida, 0} -> {:ok, salida}
      {salida, status} -> {:error, "gh workflow run falló (status #{status}):\n#{salida}"}
    end
  end
end
