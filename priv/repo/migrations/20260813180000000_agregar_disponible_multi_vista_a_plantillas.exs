defmodule MetadataApp.Repo.Migrations.AgregarDisponibleMultiVistaAPlantillas do
  use Ecto.Migration

  def change do
    alter table(:meta_schema_plantillas) do
      add :disponible_multi_vista, :boolean, default: false, null: false
    end
  end
end
