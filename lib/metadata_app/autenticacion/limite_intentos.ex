defmodule MetadataApp.Autenticacion.LimiteIntentos do
  @moduledoc """
  Límite de intentos fallidos de `/api/movil/login` y `/api/movil/
  verificar` (SPEC-API-0409202601, R10/R11, design.md §3) -- 5 fallos
  en 15 minutos por email bloquean intentos nuevos para ESE email.

  Mismo patrón que `MetadataApp.Permissions.Cache`: GenServer dueño de
  una tabla ETS pública, en su propio proceso del árbol de supervisión
  para que la tabla sobreviva a quien la consulta -- pero acá, a
  diferencia de Permissions (separado en Cache + lógica en otro
  módulo), el volumen es chico y las funciones públicas viven en este
  mismo módulo.

  Deliberadamente en memoria (`:ets`), no en la base -- una ventana de
  15 minutos no necesita sobrevivir un reinicio del nodo, y evita una
  tabla/migración nueva solo para esto.
  """
  use GenServer

  @tabla __MODULE__
  @ventana_segundos 15 * 60
  @maximo_intentos 5

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @impl true
  def init(:ok) do
    :ets.new(@tabla, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{}}
  end

  @doc "true si `email` ya llegó al máximo de intentos fallidos dentro de la ventana."
  def bloqueado?(email) do
    length(intentos_vigentes(email)) >= @maximo_intentos
  end

  @doc "Segundos que faltan para que el bloqueo actual expire -- 0 si no está bloqueado."
  def reintentar_en_segundos(email) do
    case intentos_vigentes(email) do
      [] ->
        0

      intentos ->
        mas_viejo = Enum.min(intentos)
        max(0, @ventana_segundos - (agora() - mas_viejo))
    end
  end

  @doc "Registra un intento fallido para `email` -- podar los vencidos de paso."
  def registrar_intento_fallido(email) do
    email = normalizar(email)
    nuevos = [agora() | intentos_vigentes(email)]
    :ets.insert(@tabla, {email, nuevos})
    :ok
  end

  @doc "Limpia el contador de `email` -- llamado después de un login exitoso."
  def limpiar(email) do
    :ets.delete(@tabla, normalizar(email))
    :ok
  end

  defp intentos_vigentes(email) do
    email = normalizar(email)
    limite = agora() - @ventana_segundos

    case :ets.lookup(@tabla, email) do
      [{^email, timestamps}] -> Enum.filter(timestamps, &(&1 > limite))
      [] -> []
    end
  end

  defp normalizar(email), do: String.downcase(String.trim(email))
  defp agora, do: System.system_time(:second)
end
