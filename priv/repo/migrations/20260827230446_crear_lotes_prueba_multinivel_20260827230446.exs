defmodule MetadataApp.Repo.Migrations.CrearLotesPruebaMultinivel20260827230446 do
  use Ecto.Migration

  def change do
    create table(:lotes_prueba_multinivel) do
      add :lotes_prueba_multinivel_numero_lote, :string, size: 30, null: false

      add :insert_guid, :string, size: 32, null: false
      add :update_guid, :string, size: 32, null: true
      add :delete_guid, :string, size: 32, null: true

      add :estado_id, references(:meta_schema_estados), null: true

      add :fecha_registro, :utc_datetime, null: true

      add :encabezado_id, references(:partidas_prueba_multinivel), null: false
      add :renglon_id, :integer, null: false

    end

    create unique_index(:lotes_prueba_multinivel, [:encabezado_id, :lotes_prueba_multinivel_numero_lote], name: :lotes_prueba_multinivel_unico_index)
    create unique_index(:lotes_prueba_multinivel, [:encabezado_id, :renglon_id], name: :lotes_prueba_multinivel_encabezado_renglon_unico_index)

  end
end
