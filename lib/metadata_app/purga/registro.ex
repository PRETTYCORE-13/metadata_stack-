defmodule MetadataApp.Purga.Registro do
  @moduledoc "Un renglón de la bitácora de retiros y purgas (SPEC-ARQ-3009202601, R12)."

  use Ecto.Schema
  import Ecto.Changeset

  schema "meta_schema_purgas" do
    field :artefacto, :string
    field :accion, :string
    field :tablas, :map, default: %{}
    field :versiones, {:array, :integer}, default: []
    field :respaldo, :string
    field :resultado, :string
    field :mensaje, :string
    field :usuario_email, :string

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @campos [
    :artefacto,
    :accion,
    :tablas,
    :versiones,
    :respaldo,
    :resultado,
    :mensaje,
    :usuario_email
  ]

  def changeset(registro, attrs) do
    registro
    |> cast(attrs, @campos)
    |> validate_required([:artefacto, :accion, :resultado, :usuario_email])
    |> validate_inclusion(:accion, ["retiro", "purga"])
    |> validate_inclusion(:resultado, ["ok", "error", "sin_cambios"])
  end
end
