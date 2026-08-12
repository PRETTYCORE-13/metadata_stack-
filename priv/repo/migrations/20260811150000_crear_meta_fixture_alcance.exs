defmodule MetadataApp.Repo.Migrations.CrearMetaFixtureAlcance do
  use Ecto.Migration

  def change do
    # Catálogo de test dedicado a probar aplicar_alcance_de_datos/3 (Fase
    # 4a, 2026-08-11) -- separado a propósito de meta_fixture_cliente (ese
    # pasa por el macro MetaCatalogoGenerico, que le agregaría validaciones
    # de negocio no deseadas a lo que acá son columnas de sistema).
    create table(:meta_fixture_alcance) do
      add :nombre, :string, null: false
      add :creado_por_id, references(:meta_schema_usuario, on_delete: :nilify_all)
      add :branch_id, references(:meta_schema_branch, on_delete: :nilify_all)
      add :sales_unit_id, references(:meta_schema_sales_unit, on_delete: :nilify_all)
      add :inventory_id, references(:meta_schema_inventory_location, on_delete: :nilify_all)

      add :insert_guid, :string
      add :update_guid, :string
      add :delete_guid, :string

      timestamps(type: :utc_datetime)
    end
  end
end
