defmodule MetadataApp.Integraciones.AccionLog do
  @moduledoc """
  Fase 8 de "Integraciones" (2026-08-07) — una fila por ejecución real de
  una AccionExterna (ver Integraciones.ejecutar_accion/3, que la escribe).
  Sin changeset propio -- se crea SIEMPRE con Ecto.Changeset.change/2
  directo desde código interno del contexto, nunca desde un form.
  """
  use Ecto.Schema

  schema "meta_schema_accion_log" do
    belongs_to :accion, MetadataApp.Integraciones.AccionExterna
    belongs_to :credencial, MetadataApp.Integraciones.Credencial
    belongs_to :usuario, MetadataApp.Autenticacion.Usuario

    field :accion_nombre, :string
    field :catalogo, :string
    field :registro_id, :integer
    # "usuario" (botón en la Ficha 360°) | "regla_post" (síncrono, dentro
    # de la transacción de una transición) -- ver ejecutar_accion/3.
    field :origen, :string
    field :ok, :boolean
    field :status_http, :integer
    field :error, :string
    field :duracion_ms, :integer

    timestamps(type: :utc_datetime, updated_at: false)
  end
end
