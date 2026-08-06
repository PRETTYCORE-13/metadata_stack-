defmodule MetadataApp.Repo.Migrations.AgregarColumnasEstructuralesVisiblesAHeader do
  use Ecto.Migration

  def change do
    alter table(:meta_schema_header) do
      add :mostrar_id_en_tabla, :boolean, null: false, default: true
      add :mostrar_estado_en_tabla, :boolean, null: false, default: true
      add :mostrar_trn_en_tabla, :boolean, null: false, default: true
    end
  end
end
