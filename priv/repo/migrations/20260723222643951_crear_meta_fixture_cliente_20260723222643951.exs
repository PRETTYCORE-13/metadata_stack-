defmodule MetadataApp.Repo.Migrations.CrearMetaFixtureCliente20260723222643951 do
  use Ecto.Migration

  def change do
    create table(:meta_fixture_cliente) do
      add :meta_fixture_cliente_nombre, :string, size: 100, null: false
      add :meta_fixture_cliente_edad, :integer, null: false
      add :meta_fixture_cliente_venta, :decimal, precision: 10, scale: 2, null: false

      add :insert_guid, :string, size: 32, null: false
      add :update_guid, :string, size: 32, null: true
      add :delete_guid, :string, size: 32, null: true

      add :estado_id, references(:meta_schema_estados), null: true

    end

    create unique_index(:meta_fixture_cliente, [:meta_fixture_cliente_nombre, :meta_fixture_cliente_edad, :meta_fixture_cliente_venta], name: :meta_fixture_cliente_unico_index)

  end
end
