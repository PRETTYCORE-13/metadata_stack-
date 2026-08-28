defmodule MetadataApp.Repo.Migrations.CrearPartidasPruebaMultinivel20260827230445 do
  use Ecto.Migration

  def change do
    create table(:partidas_prueba_multinivel) do
      add :partidas_prueba_multinivel_producto, :string, size: 100, null: false

      add :insert_guid, :string, size: 32, null: false
      add :update_guid, :string, size: 32, null: true
      add :delete_guid, :string, size: 32, null: true

      add :estado_id, references(:meta_schema_estados), null: true

      add :fecha_registro, :utc_datetime, null: true

      add :encabezado_id, references(:pedido_prueba_multinivel), null: false
      add :renglon_id, :integer, null: false

    end

    create unique_index(:partidas_prueba_multinivel, [:encabezado_id, :partidas_prueba_multinivel_producto], name: :partidas_prueba_multinivel_unico_index)
    create unique_index(:partidas_prueba_multinivel, [:encabezado_id, :renglon_id], name: :partidas_prueba_multinivel_encabezado_renglon_unico_index)

  end
end
