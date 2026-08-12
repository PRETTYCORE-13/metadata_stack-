defmodule MetadataApp.MetaBusinessProcess.Reglas.MetaFixtureCliente.Post do
  @moduledoc false
  # POST del fixture de test meta_fixture_cliente — usado por
  # test/metadata_app/integraciones_reglas_post_test.exs (Fase 5 de
  # "Integraciones", 2026-08-07) para probar de punta a punta que una
  # regla post puede llamar Integraciones.ejecutar/4 de forma síncrona,
  # dentro de la misma transacción de la transición -- y que un error de
  # la API externa efectivamente revierte el guardado local (ver
  # MetadataApp.MetaStateEngine.ReglaPost). scope: :sistema -- una regla
  # post no tiene un %Scope{} real a mano (Fase 8 del modelo de Alcance de
  # Datos, ver moduledoc de Integraciones.ejecutar/4).
  @behaviour MetadataApp.MetaStateEngine.ReglaPost

  @impl true
  def ejecutar(accion, registro, _contexto, _repo) do
    case accion do
      "activar_con_integracion" ->
        case MetadataApp.Integraciones.ejecutar("validar_externo", registro, :sistema, timeout: 5_000) do
          {:ok, %{status: status}} when status in 200..299 -> {:ok, :sin_cambios}
          {:ok, %{status: status}} -> {:error, "sistema externo respondió #{status}"}
          {:error, motivo} -> {:error, "no se pudo validar externamente: #{inspect(motivo)}"}
        end

      _ ->
        {:ok, :sin_cambios}
    end
  end
end
