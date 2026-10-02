defmodule MetadataApp.Workers.PurgaUnstableWorker do
  @moduledoc """
  "Purgar en unstable" en un solo paso (SPEC-ARQ-3009202601, R6, design
  §6.1): retira el artefacto, reconstruye `unstable` con `ci.yml` y, cuando
  la imagen nueva ya no lo trae, lo purga.

  Cada ejecución hace un `paso/2` y, mientras la imagen todavía trae el
  artefacto, se vuelve a programar cada 2 minutos (`{:snooze, 120}`), hasta
  45 minutos. `ci.yml` se dispara solo en el primer intento.

  Avisa a la pantalla por PubSub en `topico/0`:
  `{:purga_unstable, maestro, estado, mensaje}` con estado
  `:esperando_imagen | :purgado | :fallido`.

  Las confirmaciones (nombre y registros) se piden antes de encolar. Si al
  final hay más registros que los confirmados, se detiene y pide confirmar
  de nuevo.
  """
  use Oban.Worker,
    queue: :purga,
    max_attempts: 1,
    unique: [period: :infinity, keys: [:maestro], states: [:available, :scheduled, :executing]]

  alias MetadataApp.Purga

  @canal "unstable"
  @espera 120
  @limite_segundos 45 * 60
  @topico "purga"

  def topico, do: @topico

  @doc "Encola la purga de `maestro` en unstable."
  def encolar(maestro, ambiente_id, usuario_email, filas_confirmadas) do
    %{
      maestro: maestro,
      ambiente_id: ambiente_id,
      usuario_email: usuario_email,
      filas_confirmadas: filas_confirmadas
    }
    |> new()
    |> Oban.insert()
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: args, inserted_at: inicio} = job) do
    ambiente = MetadataApp.Ambientes.obtener_ambiente!(args["ambiente_id"])
    segundos = DateTime.diff(DateTime.utc_now(), inicio)

    paso(args, %{
      ambiente: ambiente,
      primer_intento: primer_intento?(job),
      segundos: segundos,
      retirar: &Purga.retirar(&1, ambiente, &2),
      disparar_ci: &disparar_ci/0,
      preparar: &Purga.preparar(&1, @canal, ambiente),
      purgar: &Purga.purgar(&1, @canal, ambiente, &2, &3),
      avisar: &avisar/3
    })
  end

  @doc """
  ¿Es la primera ejecución? `snooze` no cuenta como intento: Oban le resta 1
  a `attempt` y lleva la cuenta en `meta["snoozed"]` (Oban 2.24). Con
  `attempt == 1` el retiro y el disparo de CI se repetían en cada revisión.
  """
  def primer_intento?(%Oban.Job{meta: meta}), do: Map.get(meta || %{}, "snoozed", 0) == 0

  @doc """
  Un paso del trabajo. `d`: dependencias (las reales salen de `perform/1`).
  `:ok` (terminó, bien o mal: ya avisó) | `{:snooze, segundos}`.
  """
  def paso(%{"maestro" => maestro, "usuario_email" => email, "filas_confirmadas" => filas}, d) do
    # El retiro (y su registro en la bitácora) solo en el primer intento:
    # los siguientes solo esperan la imagen nueva.
    retiro = if d.primer_intento, do: d.retirar.(maestro, email), else: {:ok, :ya}

    with {:ok, _} <- retiro,
         {:ok, prep} <- d.preparar.(maestro) do
      cond do
        prep.impacto["imagen_incluye"] != true and prep.bloqueo != nil ->
          terminar(d, maestro, :fallido, prep.bloqueo)

        prep.impacto["imagen_incluye"] != true ->
          case d.purgar.(maestro, email, %{nombre: maestro, filas: filas}) do
            {:ok, _} -> terminar(d, maestro, :purgado, "#{maestro} quedó purgado en #{@canal}.")
            {:error, mensaje} -> terminar(d, maestro, :fallido, mensaje)
          end

        d.segundos > @limite_segundos ->
          terminar(
            d,
            maestro,
            :fallido,
            "Pasaron 45 minutos y #{@canal} todavía corre una imagen con #{maestro}. Revisa el run de CI y vuelve a intentar."
          )

        true ->
          esperar(d, maestro)
      end
    else
      {:error, mensaje} -> terminar(d, maestro, :fallido, mensaje)
    end
  end

  defp esperar(d, maestro) do
    if d.primer_intento do
      case d.disparar_ci.() do
        :ok ->
          d.avisar.(
            maestro,
            :esperando_imagen,
            "Retirado. Reconstruyendo #{@canal}; se purga en cuanto la imagen nueva esté arriba."
          )

          {:snooze, @espera}

        {:error, mensaje} ->
          terminar(
            d,
            maestro,
            :fallido,
            "Retirado, pero no se pudo reconstruir #{@canal}: #{mensaje}"
          )
      end
    else
      {:snooze, @espera}
    end
  end

  defp terminar(d, maestro, estado, mensaje) do
    d.avisar.(maestro, estado, mensaje)
    :ok
  end

  defp disparar_ci do
    case MetadataApp.Purga.Releases.gh(["workflow", "run", "ci.yml", "--ref", "main"]) do
      {:ok, {_, 0}} ->
        :ok

      {:ok, {salida, status}} ->
        {:error, "gh workflow run (status #{status}): #{String.trim(salida)}"}

      error ->
        error
    end
  end

  defp avisar(maestro, estado, mensaje) do
    Phoenix.PubSub.broadcast(
      MetadataApp.PubSub,
      @topico,
      {:purga_unstable, maestro, estado, mensaje}
    )
  end
end
