defmodule MetadataApp.MetaSchema.AuditoriaDefinicion do
  use Ecto.Schema
  import Ecto.Changeset

  # Log append-only (roadmap #13) -- nunca se edita ni se borra una fila
  # de acá. Contraparte de MetadataApp.MetaSchema.Auditoria (#6), pero
  # para la DEFINICIÓN de un catálogo (crear/actualizar/eliminar el
  # schema_context_name mismo), no sus registros.
  schema "meta_schema_auditoria_definicion" do
    field :schema_context_name, :string
    field :operacion, :string
    field :detalle, :map
    field :usuario_id, :integer
    field :usuario_email, :string
    field :empresa_id, :integer
    field :ip, :string
    field :user_agent, :string

    timestamps(updated_at: false, type: :utc_datetime)
  end

  @requeridos [:schema_context_name, :operacion, :detalle]
  @opcionales [:usuario_id, :usuario_email, :empresa_id, :ip, :user_agent]

  def changeset(auditoria, attrs) do
    auditoria
    |> cast(attrs, @requeridos ++ @opcionales)
    |> validate_required(@requeridos)
  end
end
