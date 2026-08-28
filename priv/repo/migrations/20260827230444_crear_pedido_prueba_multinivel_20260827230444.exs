defmodule MetadataApp.Repo.Migrations.CrearPedidoPruebaMultinivel20260827230444 do
  use Ecto.Migration

  def change do
    create table(:pedido_prueba_multinivel) do
      add :pedido_prueba_multinivel_folio, :string, size: 20, null: false

      add :insert_guid, :string, size: 32, null: false
      add :update_guid, :string, size: 32, null: true
      add :delete_guid, :string, size: 32, null: true

      add :estado_id, references(:meta_schema_estados), null: true

      add :fecha_registro, :utc_datetime, null: true

    end

    create unique_index(:pedido_prueba_multinivel, [:pedido_prueba_multinivel_folio], name: :pedido_prueba_multinivel_unico_index)

  end
end
