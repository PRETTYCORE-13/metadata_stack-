defmodule MetadataApp.Repo.Migrations.CrearMetaSchemaConsulta do
  use Ecto.Migration

  def change do
    create table(:meta_schema_consulta) do
      add :meta_schema_header_id, references(:meta_schema_header), null: false
      add :catalogo_base, :string, null: false

      # Lista de campos seleccionados: [%{"catalogo" =>, "campo" =>,
      # "etiqueta" =>, "orden" =>, "visible" =>, "totalizar" =>}, ...] —
      # columna jsonb (Ecto la mapea como {:array, :map} en el schema, no
      # :map — esto es un ARRAY de objetos, no un objeto plano).
      add :campos, :map, null: false, default: fragment("'[]'::jsonb")

      # Reservado para joins (Fase 2, todavía sin usar) — mismo formato:
      # [%{"catalogo" =>, "campo_local" =>, "campo_referencia" =>}, ...]
      add :joins, :map, null: false, default: fragment("'[]'::jsonb")

      add :insert_guid, :string, size: 32, null: false
      add :update_guid, :string, size: 32, null: true
      add :delete_guid, :string, size: 32, null: true

      timestamps(type: :utc_datetime)
    end

    create unique_index(:meta_schema_consulta, [:meta_schema_header_id])
  end
end
