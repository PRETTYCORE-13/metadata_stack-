defmodule MetadataApp.Repo.Migrations.AgregarRequiereFolioAMetaSchemaHeader do
  use Ecto.Migration

  # SPEC-SYS-0109202601 (Administrador de Folios) — mismo criterio que
  # schema_es_transaccional/codigo_trn: un flag más en el header, no una
  # tabla de "catálogos con folio" aparte. Nullable a nivel de aplicación
  # (MetadataApp.IdentificadoresTransaccionales corre en cada alta,
  # design.md §5) — el default false preserva a todo catálogo ya
  # publicado sin folio.
  def change do
    alter table(:meta_schema_header) do
      add :requiere_folio, :boolean, null: false, default: false
    end
  end
end
