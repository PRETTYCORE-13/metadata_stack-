defmodule MetadataApp.Repo.Migrations.AgregarMostrarFolioEnTabla do
  use Ecto.Migration

  # SPEC-SYS-0109202601 (Administrador de Folios), R9 — mismo patrón que
  # mostrar_trn_en_tabla: columna de presentación pura (Get View),
  # default true (mismo criterio que TRN/Estado/ID).
  def change do
    alter table(:meta_schema_header) do
      add :mostrar_folio_en_tabla, :boolean, default: true, null: false
    end
  end
end
