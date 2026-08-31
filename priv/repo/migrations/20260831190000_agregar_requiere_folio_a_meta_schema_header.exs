defmodule MetadataApp.Repo.Migrations.AgregarRequiereFolioAMetaSchemaHeader do
  use Ecto.Migration

  # NDT (Numeración de Documentos Transaccionales) — mismo criterio que
  # schema_es_transaccional/codigo_trn (Fase 1 de TRN): un flag más en el
  # header, no una tabla de "catálogos con folio" aparte. Nullable a nivel
  # de aplicación (MetadataApp.Folio.asignar_si_configurado/1 corre en
  # cada alta, igual que TRN) — el default false preserva a todo catálogo
  # ya publicado sin folio, tal como pasó con schema_es_transaccional.
  def change do
    alter table(:meta_schema_header) do
      add :requiere_folio, :boolean, null: false, default: false
    end
  end
end
