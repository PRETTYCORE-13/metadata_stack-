defmodule MetadataApp.Purga.Respaldo do
  @moduledoc """
  Respaldo de las tablas de un artefacto antes de purgarlo en un cliente
  (SPEC-ARQ-3009202601, R10-R11, design §6). `pg_dump` dentro del pod de
  Postgres; el archivo queda en el disco del servidor, nunca sale de ahí.

  Vive en el home del usuario SSH (`$HOME/metadata-purgas/<sistema>/`):
  ese usuario solo tiene sudo sin contraseña para `k3s`, así que nada más
  `kubectl` va con `sudo` (encontrado real, 2026-10-02: con `sudo mkdir`
  en `/var/backups` el respaldo fallaba pidiendo contraseña).

  La retención de 30 días se aplica en cada respaldo: no hay cron.
  """

  @dir "metadata-purgas"
  @dias_retencion 30

  @doc """
  `{:ok, ruta_absoluta}` | `{:error, mensaje}`. `ejecutor`: mismo contrato
  que `MetadataApp.Ssh.ejecutar/2`.
  """
  def crear(
        ambiente,
        sistema,
        artefacto,
        tablas,
        ejecutor \\ &MetadataApp.Ssh.ejecutar/2,
        ahora \\ DateTime.utc_now()
      ) do
    case ejecutor.(ambiente, comando(sistema, tablas, archivo(artefacto, ahora))) do
      {:ok, 0, salida} ->
        # Última línea: "<bytes> <ruta absoluta>" (stat -c '%s %n').
        case salida
             |> String.split(~r/\r?\n/, trim: true)
             |> List.last()
             |> to_string()
             |> String.split(" ", parts: 2) do
          [bytes, ruta] ->
            case Integer.parse(bytes) do
              {n, ""} when n > 0 -> {:ok, String.trim(ruta)}
              _ -> {:error, "El respaldo quedó vacío (#{String.trim(ruta)}). No se purgó nada."}
            end

          _ ->
            {:error, "No se pudo medir el respaldo. No se purgó nada."}
        end

      {:ok, status, salida} ->
        {:error,
         "Falló el respaldo (status #{status}): #{String.trim(salida)}. No se purgó nada."}

      {:error, motivo} ->
        {:error, "SSH falló al respaldar: #{inspect(motivo)}. No se purgó nada."}
    end
  end

  @doc false
  def archivo(artefacto, ahora),
    do: "#{artefacto}_#{Calendar.strftime(ahora, "%Y%m%d%H%M%S")}.dump"

  @doc false
  def comando(sistema, tablas, archivo) do
    validar!(sistema, tablas)
    banderas = Enum.map_join(tablas, " ", &"-t #{&1}")
    dir = ~s|"$HOME/#{@dir}/#{sistema}"|

    # pipefail: si pg_dump falla, el status no queda tapado por la
    # redirección. bash -c explícito: no depende del shell de login.
    script = """
    set -o pipefail
    mkdir -p #{dir}
    find "$HOME/#{@dir}" -name '*.dump' -mtime +#{@dias_retencion} -delete
    sudo k3s kubectl exec -n metadata-stack aws-postgres-0 -- pg_dump -U appuser -d db_#{sistema} -Fc #{banderas} > #{dir}/#{archivo}
    stat -c '%s %n' #{dir}/#{archivo}
    """

    "bash -c " <> comilla_simple(script)
  end

  defp comilla_simple(texto), do: "'" <> String.replace(texto, "'", "'\\''") <> "'"

  # Todo lo que entra al comando viene de nombres ya validados; esto es la
  # última barrera contra inyección de shell.
  defp validar!(sistema, tablas) do
    unless Regex.match?(~r/^[a-z0-9]([a-z0-9-]*[a-z0-9])?$/, sistema),
      do: raise(ArgumentError, "sistema inválido")

    unless tablas != [] and Enum.all?(tablas, &MetadataApp.Purga.Unidad.nombre_valido?/1),
      do: raise(ArgumentError, "tablas inválidas")
  end
end
