defmodule MetadataApp.Purga do
  @moduledoc """
  Orquesta, desde el BPB local, retirar y purgar artefactos
  (SPEC-ARQ-3009202601). La parte de GitHub vive en `Purga.Releases`; la
  de cada sistema destino, en `Purga.Remoto` → `bin/purga`.

  `deps` (solo se cambia en pruebas):
  - `:gh` — `fn args -> {:ok, {salida, status}} | {:error, m} end`
  - `:remoto` — `fn ambiente, sistema, solicitud -> {:ok, datos} | {:error, m} end`
  - `:cache_dir` — dónde guardar los paquetes descargados
  - `:tmp_dir` — dónde armar los paquetes a subir
  """

  alias MetadataApp.Purga.{Releases, Remoto}

  @canal_retiro "unstable"

  defp deps(opts) do
    %{
      gh: Keyword.get(opts, :gh, &Releases.gh/1),
      remoto: Keyword.get(opts, :remoto, &Remoto.llamar/3),
      cache_dir: Keyword.get(opts, :cache_dir, Releases.cache_dir()),
      tmp_dir:
        Keyword.get(
          opts,
          :tmp_dir,
          Path.join(
            System.tmp_dir!(),
            "metadata_purga_subir_#{System.unique_integer([:positive])}"
          )
        )
    }
  end

  ## Retirar (R4, design §4.1)

  @doc """
  Saca `maestro` de los paquetes que restaura cada build y deja su
  inventario en `retirado-<maestro>`. Idempotente.

  `{:ok, resumen}` | `{:error, mensaje}`. `resumen`:
  `%{resultado: "ok" | "sin_cambios", modificados: [tag], bc_propio: ...}`.
  """
  def retirar(maestro, ambiente, usuario_email, opts \\ []) do
    d = deps(opts)

    try do
      hacer_retiro(d, maestro, ambiente, usuario_email)
    after
      File.rm_rf(d.tmp_dir)
    end
  end

  defp hacer_retiro(d, maestro, ambiente, usuario_email) do
    with {:ok, paquetes} <- Releases.leer(d.gh, d.cache_dir),
         {:ok, plan} <- Releases.plan_retiro(maestro, paquetes) do
      if plan.nada_que_hacer do
        registrar_retiro(d, ambiente, plan, usuario_email, "sin_cambios", "Ya estaba retirado.")
        {:ok, %{resultado: "sin_cambios", modificados: [], bc_propio: :no_existe}}
      else
        with :ok <- sin_dependencias(d, ambiente, plan),
             :ok <- subir_inventario(d, plan),
             :ok <- resubir_modificados(d, plan),
             :ok <- resolver_bc_propio(d, plan) do
          mensaje = mensaje_retiro(plan)
          registrar_retiro(d, ambiente, plan, usuario_email, "ok", mensaje)

          {:ok,
           %{
             resultado: "ok",
             modificados: Enum.map(plan.modificados, & &1.tag),
             bc_propio: resumen_bc(plan.bc_propio),
             mensaje: mensaje
           }}
        else
          {:error, mensaje} = error ->
            registrar_retiro(d, ambiente, plan, usuario_email, "error", mensaje)
            error
        end
      end
    end
  end

  # Una lápida ya no tiene tablas ni metadata en ningún lado: no hay
  # dependencias que revisar.
  defp sin_dependencias(_d, _ambiente, %{tipo: :lapida}), do: :ok

  defp sin_dependencias(d, ambiente, plan) do
    solicitud = %{
      "op" => "impacto",
      "artefacto" => plan.maestro,
      "tablas" => plan.tablas,
      "versiones" => []
    }

    case d.remoto.(ambiente, @canal_retiro, solicitud) do
      {:ok, %{"dependencias" => []}} ->
        :ok

      {:ok, %{"dependencias" => deps}} ->
        {:error, "No se puede retirar: " <> Enum.join(deps, " ")}

      {:error, :sin_purga} ->
        {:error,
         "#{@canal_retiro} todavía corre una versión sin purga: no se pueden revisar las dependencias."}

      {:error, mensaje} ->
        {:error, "No se pudieron revisar las dependencias en #{@canal_retiro}: #{mensaje}"}
    end
  end

  defp subir_inventario(d, plan) do
    tag = "retirado-#{plan.maestro}"
    path = Releases.empaquetar(plan.inventario, Path.join(d.tmp_dir, tag))

    notas =
      "Inventario del retiro de #{plan.maestro} (SPEC-ARQ-3009202601). No se restaura en ningún build."

    with :ok <- asegurar_release(d.gh, tag, plan.maestro, notas) do
      gh_ok(d.gh, ["release", "upload", tag, path, "--clobber"], "subir el inventario #{tag}")
    end
  end

  defp resubir_modificados(d, plan) do
    Enum.reduce_while(plan.modificados, :ok, fn %{tag: tag, archivos: archivos}, :ok ->
      path = Releases.empaquetar(archivos, Path.join(d.tmp_dir, tag))

      case gh_ok(
             d.gh,
             ["release", "upload", tag, path, "--clobber"],
             "volver a subir #{tag} sin #{plan.maestro}"
           ) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp resolver_bc_propio(_d, %{bc_propio: :no_existe}), do: :ok

  defp resolver_bc_propio(d, %{bc_propio: :borrar, maestro: maestro}) do
    gh_ok(
      d.gh,
      ["release", "delete", "bc-#{maestro}", "--yes", "--cleanup-tag"],
      "borrar bc-#{maestro}"
    )
  end

  defp resolver_bc_propio(d, %{bc_propio: {:conservar, archivos, _}, maestro: maestro}) do
    tag = "bc-#{maestro}"
    path = Releases.empaquetar(archivos, Path.join(d.tmp_dir, tag))

    gh_ok(
      d.gh,
      ["release", "upload", tag, path, "--clobber"],
      "volver a subir #{tag} sin #{maestro}"
    )
  end

  defp resumen_bc({:conservar, _, catalogos}), do: {:conservado, catalogos}
  defp resumen_bc(:borrar), do: :borrado
  defp resumen_bc(otro), do: otro

  defp mensaje_retiro(plan) do
    partes =
      [
        plan.modificados != [] &&
          "Se sacó de: #{Enum.map_join(plan.modificados, ", ", & &1.tag)}.",
        plan.bc_propio == :borrar && "Se borró bc-#{plan.maestro}.",
        match?({:conservar, _, _}, plan.bc_propio) &&
          "bc-#{plan.maestro} se conservó porque es el único que publica: #{Enum.join(elem(plan.bc_propio, 2), ", ")}."
      ]

    partes |> Enum.filter(&is_binary/1) |> Enum.join(" ")
  end

  # La bitácora de un retiro vive en unstable (design §4). Si unstable no
  # responde, el retiro ya ocurrió en GitHub: no se revierte por eso.
  defp registrar_retiro(d, ambiente, plan, usuario_email, resultado, mensaje) do
    registro = %{
      "artefacto" => plan.maestro,
      "accion" => "retiro",
      "tablas" => Map.new(plan.tablas, &{&1, 0}),
      "versiones" => Releases.versiones(plan.inventario),
      "resultado" => resultado,
      "mensaje" => mensaje,
      "usuario_email" => usuario_email
    }

    d.remoto.(ambiente, @canal_retiro, %{"op" => "registrar", "registro" => registro})
  end

  ## Purgar en un destino (R6-R11, design §6)

  @doc """
  Lo que se purgaría de `maestro` en `sistema`, para mostrarlo antes de
  confirmar. Sale del inventario `retirado-<maestro>`: sin retiro no hay
  purga (R6).

  `{:ok, %{maestro, sistema, tablas, versiones, impacto, cliente, bloqueo}}`
  | `{:error, mensaje}`. `bloqueo` es `nil` o el motivo por el que no se
  puede purgar todavía.
  """
  def preparar(maestro, sistema, ambiente, opts \\ []) do
    d = deps(opts)

    clientes =
      Keyword.get_lazy(opts, :clientes, fn -> Map.keys(MetadataApp.MotorAlta.leer_sistemas()) end)

    with :ok <- validar_destino(sistema, clientes),
         {:ok, paquetes} <- Releases.leer(d.gh, d.cache_dir),
         {:ok, inventario} <-
           inventario(maestro, paquetes, Keyword.get(opts, :antes_de_retirar, false)) do
      tablas = tablas_de_inventario(maestro, inventario)
      versiones = Releases.versiones(inventario)

      solicitud = %{
        "op" => "impacto",
        "artefacto" => maestro,
        "tablas" => tablas,
        "versiones" => versiones
      }

      case d.remoto.(ambiente, sistema, solicitud) do
        {:ok, impacto} ->
          {:ok,
           %{
             maestro: maestro,
             sistema: sistema,
             tablas: tablas,
             versiones: versiones,
             impacto: impacto,
             cliente: sistema in clientes,
             bloqueo: bloqueo(impacto, sistema)
           }}

        {:error, :sin_purga} ->
          {:error, "#{sistema} todavía corre una versión sin purga."}

        {:error, mensaje} ->
          {:error, "No se pudo consultar #{sistema}: #{mensaje}"}
      end
    end
  end

  @doc """
  Purga `maestro` en `sistema` (R7). `confirmacion`: `%{nombre: texto
  escrito, filas: registros que el usuario aceptó perder}` (R8, R9).
  En un cliente, respalda antes (R10); si el respaldo falla, no purga.
  """
  def purgar(maestro, sistema, ambiente, usuario_email, confirmacion, opts \\ []) do
    d = deps(opts)
    ssh = Keyword.get(opts, :ssh, &MetadataApp.Ssh.ejecutar/2)

    with {:ok, prep} <- preparar(maestro, sistema, ambiente, opts),
         :ok <- sin_bloqueo(prep),
         :ok <- validar_confirmacion(prep, confirmacion),
         {:ok, respaldo} <- respaldar(prep, ambiente, ssh) do
      solicitud = %{
        "op" => "ejecutar",
        "artefacto" => maestro,
        "tablas" => prep.tablas,
        "versiones" => prep.versiones,
        "filas_confirmadas" => confirmacion.filas,
        "usuario_email" => usuario_email,
        "respaldo" => respaldo
      }

      case d.remoto.(ambiente, sistema, solicitud) do
        {:ok, datos} -> {:ok, Map.put(datos, "respaldo", respaldo)}
        {:error, mensaje} -> {:error, if(is_binary(mensaje), do: mensaje, else: inspect(mensaje))}
      end
    end
  end

  defp validar_destino(sistema, clientes) do
    if sistema in MetadataApp.MotorAlta.canales() or sistema in clientes,
      do: :ok,
      else: {:error, "\"#{sistema}\" no es un canal ni un cliente de priv/sistemas.json."}
  end

  # `antes_de_retirar`: "Purgar en unstable" en un solo paso muestra el
  # impacto antes de retirar; el inventario sale entonces del plan de retiro.
  defp inventario(maestro, paquetes, antes_de_retirar) do
    case Map.fetch(paquetes, "retirado-#{maestro}") do
      {:ok, inventario} ->
        {:ok, inventario}

      :error when antes_de_retirar ->
        with {:ok, plan} <- Releases.plan_retiro(maestro, paquetes), do: {:ok, plan.inventario}

      :error ->
        {:error,
         "#{maestro} no está retirado: primero hay que retirarlo para que ningún build lo vuelva a traer."}
    end
  end

  # Un catálogo trae sus .meta.json en el inventario; una lápida no.
  defp tablas_de_inventario(maestro, inventario) do
    case MetadataApp.Purga.Unidad.tablas_de(
           maestro,
           Releases.headers(%{"inventario" => inventario})
         ) do
      {:ok, tablas} -> tablas
      _ -> [maestro]
    end
  end

  defp bloqueo(%{"imagen_incluye" => true}, sistema) do
    "La versión que corre en #{sistema} todavía incluye este artefacto. " <>
      if(sistema == @canal_retiro,
        do: "Hay que reconstruir #{sistema} sin él.",
        else: "Propaga a #{sistema} una versión posterior al retiro."
      )
  end

  defp bloqueo(%{"dependencias" => [_ | _] = deps}, _sistema),
    do: "Hay dependencias: " <> Enum.join(deps, " ")

  defp bloqueo(_impacto, _sistema), do: nil

  defp sin_bloqueo(%{bloqueo: nil}), do: :ok
  defp sin_bloqueo(%{bloqueo: motivo}), do: {:error, motivo}

  defp validar_confirmacion(prep, confirmacion) do
    filas = prep.impacto["filas"] || 0

    cond do
      Map.get(confirmacion, :nombre) != prep.maestro ->
        {:error, "El nombre escrito no coincide con #{prep.maestro}."}

      filas > 0 and Map.get(confirmacion, :filas) != filas ->
        {:error,
         "#{prep.maestro} tiene #{filas} registro(s) en #{prep.sistema}: hay que confirmarlos."}

      true ->
        :ok
    end
  end

  # Solo clientes, y solo tablas: una vista o una función no guardan datos.
  defp respaldar(%{cliente: false}, _ambiente, _ssh), do: {:ok, nil}

  defp respaldar(prep, ambiente, ssh) do
    case for(%{"nombre" => t, "objeto" => "tabla"} <- prep.impacto["tablas"] || [], do: t) do
      [] ->
        {:ok, nil}

      tablas ->
        MetadataApp.Purga.Respaldo.crear(ambiente, prep.sistema, prep.maestro, tablas, ssh)
    end
  end

  @doc "¿Quien purga tiene `maestro` en su máquina? (R14)"
  def copia_local?(maestro), do: MetadataApp.Purga.Local.existe?(maestro)

  @doc "Borra `maestro` de esta máquina (R14). Ver `Purga.Local.purgar/3`."
  def purgar_local(maestro, usuario_email),
    do: MetadataApp.Purga.Local.purgar(maestro, usuario_email)

  @doc "Encola \"Purgar en unstable\" en un solo paso (design §6.1)."
  def encolar_purga_unstable(maestro, ambiente_id, usuario_email, filas_confirmadas) do
    MetadataApp.Workers.PurgaUnstableWorker.encolar(
      maestro,
      ambiente_id,
      usuario_email,
      filas_confirmadas
    )
  end

  ## Lectura para la pantalla (R2, R12)

  @doc """
  Artefactos publicados o retirados, leídos de GitHub.
  `{:ok, [artefacto]}` | `{:error, mensaje}` (ver `Releases.artefactos/1`).
  """
  def artefactos(opts \\ []) do
    d = deps(opts)

    with {:ok, paquetes} <- Releases.leer(d.gh, d.cache_dir),
         do: {:ok, Releases.artefactos(paquetes)}
  end

  @doc "Inventario de un destino (`Base.inventario/0` remoto): `{:ok, %{\"unidades\", \"versiones\"}}`."
  def inventario_destino(ambiente, sistema, opts \\ []) do
    deps(opts).remoto.(ambiente, sistema, %{"op" => "inventario"})
  end

  @doc "Bitácora de un destino, la más reciente primero."
  def bitacora_destino(ambiente, sistema, limite \\ 200, opts \\ []) do
    deps(opts).remoto.(ambiente, sistema, %{"op" => "bitacora", "limite" => limite})
  end

  @doc """
  ¿`artefacto` (de `artefactos/1`) existe en un destino, según su
  inventario? Por su header o, si es lápida, por alguna de sus versiones
  todavía aplicada.
  """
  def presente?(artefacto, %{"unidades" => unidades, "versiones" => versiones}) do
    Enum.any?(unidades, &(&1["maestro"] == artefacto.nombre)) or
      Enum.any?(artefacto.versiones, &(&1 in versiones))
  end

  ## Borrar inventario (R4)

  @doc """
  Borra `retirado-<maestro>` para siempre. `presente_en`: destinos donde X
  todavía existe (lo calcula la pantalla, design §7); si hay alguno, no se
  borra.
  """
  def borrar_inventario(maestro, presente_en, opts \\ [])

  def borrar_inventario(maestro, [_ | _] = presente_en, _opts) do
    {:error,
     "#{maestro} todavía existe en: #{Enum.join(presente_en, ", ")}. Púrgalo ahí antes de borrar su inventario."}
  end

  def borrar_inventario(maestro, [], opts) do
    d = deps(opts)

    gh_ok(
      d.gh,
      ["release", "delete", "retirado-#{maestro}", "--yes", "--cleanup-tag"],
      "borrar retirado-#{maestro}"
    )
  end

  ## gh

  defp asegurar_release(gh, tag, titulo, notas) do
    case gh.(["release", "view", tag]) do
      {:ok, {_, 0}} ->
        :ok

      {:ok, {salida, _}} ->
        if salida =~ "release not found",
          do:
            gh_ok(
              gh,
              ["release", "create", tag, "--title", titulo, "--notes", notas],
              "crear #{tag}"
            ),
          else: {:error, "No se pudo confirmar si #{tag} existe: #{salida}"}

      error ->
        error
    end
  end

  defp gh_ok(gh, args, que) do
    case gh.(args) do
      {:ok, {_, 0}} ->
        :ok

      {:ok, {salida, status}} ->
        {:error, "No se pudo #{que} (gh, status #{status}): #{String.trim(salida)}"}

      error ->
        error
    end
  end
end
