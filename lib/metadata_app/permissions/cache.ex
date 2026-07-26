defmodule MetadataApp.Permissions.Cache do
  @moduledoc """
  Dueño de la tabla ETS de permisos efectivos (una entrada por
  `{usuario_id, empresa_id}`). Vive en su propio proceso, arrancado en el
  árbol de supervisión, para que la tabla sobreviva aunque el proceso que
  hizo la consulta (un LiveView, un request) muera.
  """
  use GenServer

  @tabla __MODULE__

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  def tabla, do: @tabla

  @impl true
  def init(:ok) do
    :ets.new(@tabla, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{}}
  end
end
