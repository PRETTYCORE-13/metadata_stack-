defmodule MetadataApp.Purga.Respaldo do
  @moduledoc """
  Respaldo de las tablas de un artefacto antes de purgarlo en un cliente
  (SPEC-ARQ-3009202601, R10-R11, design §6). `pg_dump` dentro del pod de
  Postgres; el archivo queda en el disco del servidor, nunca sale de ahí.

  La retención de 30 días se aplica en cada respaldo: no hay cron.
  """

  @dir "/var/backups/metadata-purgas"
  @dias_retencion 30

  @doc """
  `{:ok, ruta}` | `{:error, mensaje}`. `ejecutor`: mismo contrato que
  `MetadataApp.Ssh.ejecutar/2`.
  """
  def crear(
        ambiente,
        sistema,
        artefacto,
        tablas,
        ejecutor \\ &MetadataApp.Ssh.ejecutar/2,
        ahora \\ DateTime.utc_now()
      ) do
    ruta = ruta(sistema, artefacto, ahora)

    case ejecutor.(ambiente, comando(sistema, tablas, ruta)) do
      {:ok, 0, salida} ->
        case Integer.parse(
               salida
               |> String.split(~r/\r?\n/, trim: true)
               |> List.last()
               |> to_string()
               |> String.trim()
             ) do
          {bytes, ""} when bytes > 0 -> {:ok, ruta}
          _ -> {:error, "El respaldo quedó vacío o no se pudo medir (#{ruta}). No se purgó nada."}
        end

      {:ok, status, salida} ->
        {:error,
         "Falló el respaldo (status #{status}): #{String.trim(salida)}. No se purgó nada."}

      {:error, motivo} ->
        {:error, "SSH falló al respaldar: #{inspect(motivo)}. No se purgó nada."}
    end
  end

  @doc false
  def ruta(sistema, artefacto, ahora) do
    sello = Calendar.strftime(ahora, "%Y%m%d%H%M%S")
    "#{@dir}/#{sistema}/#{artefacto}_#{sello}.dump"
  end

  @doc false
  def comando(sistema, tablas, ruta) do
    validar!(sistema, tablas)
    banderas = Enum.map_join(tablas, " ", &"-t #{&1}")

    # pipefail: si pg_dump falla, el status no queda tapado por tee.
    """
    set -o pipefail && \
    sudo mkdir -p #{@dir}/#{sistema} && \
    sudo find #{@dir} -name '*.dump' -mtime +#{@dias_retencion} -delete && \
    sudo k3s kubectl exec -n metadata-stack aws-postgres-0 -- pg_dump -U appuser -d db_#{sistema} -Fc #{banderas} | sudo tee #{ruta} > /dev/null && \
    sudo stat -c %s #{ruta}
    """
    |> String.trim()
  end

  # Todo lo que entra al comando viene de nombres ya validados; esto es la
  # última barrera contra inyección de shell.
  defp validar!(sistema, tablas) do
    unless Regex.match?(~r/^[a-z0-9]([a-z0-9-]*[a-z0-9])?$/, sistema),
      do: raise(ArgumentError, "sistema inválido")

    unless tablas != [] and Enum.all?(tablas, &MetadataApp.Purga.Unidad.nombre_valido?/1),
      do: raise(ArgumentError, "tablas inválidas")
  end
end
