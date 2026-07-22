defmodule MetadataApp.Repo.Migrations.AgregarTrnAMetaSchemaHeader do
  use Ecto.Migration

  # PrettyCore TRN (Transaction Reference Number) — Fase 1. Decisiones
  # tomadas con el usuario: campo booleano separado (no reusar
  # schema_context_type, que ya usa el valor 2 para "carpeta"), código de
  # módulo alfanumérico de 4 caracteres, sin tabla transaction_types
  # separada — meta_schema_header YA es el registro central de módulos de
  # este proyecto.
  def change do
    alter table(:meta_schema_header) do
      add :schema_es_transaccional, :boolean, null: false, default: false
      add :codigo_trn, :string, size: 4
    end

    create unique_index(:meta_schema_header, [:codigo_trn], where: "codigo_trn IS NOT NULL", name: :meta_schema_header_codigo_trn_unico_index)
  end
end
