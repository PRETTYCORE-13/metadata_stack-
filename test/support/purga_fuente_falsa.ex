defmodule MetadataApp.Purga.FuenteFalsa do
  @moduledoc """
  Reemplazo de `MetadataApp.Purga` para las pruebas de `PurgarLive`
  (SPEC-ARQ-3009202601): sin GitHub ni SSH. Se inyecta por la sesión
  (`"purga_fuente"`).

  Cada prueba guarda su configuración con `configurar/1` bajo su propio
  pid; las llamadas (desde el LiveView o sus tareas async) la encuentran
  recorriendo `$callers`, así que las pruebas pueden correr en paralelo.
  Cada llamada que modifica algo se avisa al proceso de la prueba.
  """

  def configurar(config) do
    prueba = self()
    :persistent_term.put({__MODULE__, prueba}, config)
    ExUnit.Callbacks.on_exit(fn -> :persistent_term.erase({__MODULE__, prueba}) end)
  end

  defp config do
    [self() | Process.get(:"$callers", [])]
    |> Enum.find_value(%{}, &:persistent_term.get({__MODULE__, &1}, nil))
  end

  defp prueba do
    [self() | Process.get(:"$callers", [])]
    |> Enum.find(&(:persistent_term.get({__MODULE__, &1}, nil) != nil))
  end

  defp avisar(mensaje), do: send(prueba(), mensaje)

  def artefactos, do: Map.get(config(), :artefactos, {:ok, []})

  def inventario_destino(_ambiente, destino) do
    Map.get(config(), :inventarios, %{})
    |> Map.get(destino, {:ok, %{"unidades" => [], "versiones" => []}})
  end

  def bitacora_destino(_ambiente, destino),
    do: {:ok, Map.get(config(), :bitacora, %{}) |> Map.get(destino, [])}

  def preparar(nombre, destino, _ambiente, opts) do
    avisar({:preparar, nombre, destino, opts})
    Map.fetch!(config(), :preparar)
  end

  def retirar(nombre, _ambiente, email) do
    avisar({:retirar, nombre, email})
    Map.get(config(), :retirar, {:ok, %{resultado: "ok", mensaje: ""}})
  end

  def purgar(nombre, destino, _ambiente, email, confirmacion) do
    avisar({:purgar, nombre, destino, email, confirmacion})
    Map.get(config(), :purgar, {:ok, %{"resultado" => "ok"}})
  end

  def borrar_inventario(nombre, presente_en) do
    avisar({:borrar_inventario, nombre, presente_en})
    :ok
  end

  def copia_local?(nombre), do: nombre in Map.get(config(), :copias_locales, [])

  def purgar_local(nombre, email) do
    avisar({:purgar_local, nombre, email})
    {:ok, %{archivos: 3, resultado: "ok"}}
  end

  def encolar_purga_unstable(nombre, _ambiente_id, email, filas) do
    avisar({:encolar, nombre, email, filas})
    {:ok, %{}}
  end
end
