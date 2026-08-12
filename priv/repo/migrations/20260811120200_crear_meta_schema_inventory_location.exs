defmodule MetadataApp.Repo.Migrations.CrearMetaSchemaInventoryLocation do
  use Ecto.Migration

  def change do
    # Hermano de Sales Unit bajo Branch (NO anidado bajo Sales Unit,
    # aclarado explícitamente) -- por eso denormaliza empresa_id + branch_id,
    # nunca sales_unit_id.
    create table(:meta_schema_inventory_location) do
      add :empresa_id, references(:meta_schema_empresa, on_delete: :restrict), null: false
      add :branch_id, references(:meta_schema_branch, on_delete: :restrict), null: false
      add :inventory_name, :string, null: false
      # Libres a propósito, mismo criterio que sales_unit_type -- listas
      # abiertas (planta/punto de embarque/almacén; comprometida/producto
      # terminado/producción... "etc"), no enums cerrados.
      add :inventory_type, :string
      add :inventory_function, :string

      add :insert_guid, :string
      add :update_guid, :string
      add :delete_guid, :string

      timestamps(type: :utc_datetime)
    end

    create index(:meta_schema_inventory_location, [:empresa_id])
    create index(:meta_schema_inventory_location, [:branch_id])
    create index(:meta_schema_inventory_location, [:delete_guid])
  end
end
