defmodule MetadataApp.MetaBusinessProcess.Reglas.MetaFixtureCliente.Pre do
  @moduledoc false
  # PRE del fixture de test meta_fixture_cliente (mecanismo actual: un
  # módulo por catálogo, rediseño 2026-07-21 — ver
  # MetadataApp.MetaStateEngine.ReglaPre). Reemplaza al viejo mecanismo de
  # filas TransicionRegla que usaba meta_transicion_controller_test.exs
  # contra pty_clientes, ya muerto (sin ningún uso real en el código de
  # producción).
  #
  # El despacho es por nombre de `accion` FIJO en el código — a diferencia
  # del viejo mecanismo (datos en la base), acá no se puede armar un
  # escenario con un accion generado con unique() en tiempo de test. Por
  # eso las acciones de estos dos casos son nombres fijos y descriptivos,
  # no genéricos ("activar").
  @behaviour MetadataApp.MetaStateEngine.ReglaPre

  @impl true
  def evaluar(accion, registro, contexto) do
    case accion do
      "activar_con_dato" ->
        MetadataApp.MetaStateEngine.Reglas.Pre.evaluar("dato_en_contexto", registro, contexto, %{"dato" => "motivo"})

      "activar_con_rol" ->
        MetadataApp.MetaStateEngine.Reglas.Pre.evaluar("requiere_rol", registro, contexto, %{"rol" => "supervisor"})

      _ ->
        :ok
    end
  end
end
