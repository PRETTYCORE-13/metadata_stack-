defmodule MetadataApp.Repo.Migrations.CrearMetaSchemaPurgas do
  use Ecto.Migration

  # Bitácora de retiros y purgas de artefactos (SPEC-ARQ-3009202601, R12).
  # Vive en la base del sistema destino donde ocurrió la purga. Sin FK a
  # usuario: quien purga existe en la base local de su BPB, no en esta.
  def change do
    create table(:meta_schema_purgas) do
      add :artefacto, :string, null: false
      add :accion, :string, null: false
      add :tablas, :map, null: false, default: %{}
      add :versiones, {:array, :bigint}, null: false, default: []
      add :respaldo, :string
      add :resultado, :string, null: false
      add :mensaje, :text
      add :usuario_email, :string, null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:meta_schema_purgas, [:inserted_at])
    create index(:meta_schema_purgas, [:artefacto])
  end
end
