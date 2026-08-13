defmodule MetadataApp.Repo.Migrations.CrearAsignacionesAlcanceUsuario do
  use Ecto.Migration

  def change do
    # Fase 2 del modelo de Alcance de Datos (2026-08-11) — 3 tablas N:N,
    # mismo patrón que meta_schema_usuario_empresa: un usuario puede tener
    # acceso a varias Branch/SalesUnit/InventoryLocation, ninguna se modela
    # 1:1 aunque hoy parezca que "pertenece a una sola".
    create table(:meta_schema_usuario_branch) do
      add :usuario_id, references(:meta_schema_usuario, on_delete: :delete_all), null: false
      add :branch_id, references(:meta_schema_branch, on_delete: :delete_all), null: false

      add :insert_guid, :string
      add :update_guid, :string
      add :delete_guid, :string

      timestamps(type: :utc_datetime)
    end

    create unique_index(:meta_schema_usuario_branch, [:usuario_id, :branch_id])

    create table(:meta_schema_usuario_sales_unit) do
      add :usuario_id, references(:meta_schema_usuario, on_delete: :delete_all), null: false
      add :sales_unit_id, references(:meta_schema_sales_unit, on_delete: :delete_all), null: false

      add :insert_guid, :string
      add :update_guid, :string
      add :delete_guid, :string

      timestamps(type: :utc_datetime)
    end

    create unique_index(:meta_schema_usuario_sales_unit, [:usuario_id, :sales_unit_id])

    create table(:meta_schema_usuario_inventory_location) do
      add :usuario_id, references(:meta_schema_usuario, on_delete: :delete_all), null: false
      add :inventory_id, references(:meta_schema_inventory_location, on_delete: :delete_all), null: false

      add :insert_guid, :string
      add :update_guid, :string
      add :delete_guid, :string

      timestamps(type: :utc_datetime)
    end

    # Nombre acortado a mano -- el generado automático (con el nombre de
    # tabla completo) supera el límite de 63 chars de Postgres y queda
    # truncado en silencio (confirmado en dev, mensaje informativo).
    create unique_index(:meta_schema_usuario_inventory_location, [:usuario_id, :inventory_id],
      name: :meta_schema_usuario_inv_loc_usuario_id_inventory_id_index
    )
  end
end
