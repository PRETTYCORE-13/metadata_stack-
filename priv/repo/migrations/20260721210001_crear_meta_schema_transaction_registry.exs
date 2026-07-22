defmodule MetadataApp.Repo.Migrations.CrearMetaSchemaTransactionRegistry do
  use Ecto.Migration

  # Índice central de TRNs — mismo rol arquitectónico que
  # meta_schema_transicion_eventos (log central que espeja lo que pasa en
  # cualquier catálogo dinámico), acá para poder buscar por TRN/ULID sin
  # tener que hacer UNION contra cada tabla generada del sistema. El TRN y
  # el ULID de verdad también viven como columnas físicas en la tabla de
  # cada catálogo transaccional (ver CatalogoGenerador) — esto es el
  # índice de búsqueda global, no la única fuente de verdad del dato.
  # Nombre con prefijo meta_schema_ (renombrado 2026-07-21, antes de
  # pushear) — mismo criterio de nombres que el resto de las tablas del
  # BPB (meta_schema_header/detail/estados/transiciones/...).
  def change do
    create table(:meta_schema_transaction_registry) do
      add :ulid, :string, size: 26, null: false
      add :trn, :string, size: 23, null: false
      add :meta_schema_header_id, references(:meta_schema_header), null: false
      add :entity_id, :integer, null: false
      add :company_id, :integer, null: true

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:meta_schema_transaction_registry, [:ulid], name: :meta_schema_transaction_registry_ulid_unico_index)
    create unique_index(:meta_schema_transaction_registry, [:trn], name: :meta_schema_transaction_registry_trn_unico_index)
    create index(:meta_schema_transaction_registry, [:meta_schema_header_id, :entity_id])
  end
end
