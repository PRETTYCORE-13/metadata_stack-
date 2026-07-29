defmodule MetadataApp.Repo.Migrations.CrearMetaSchemaCarpetaOrden do
  use Ecto.Migration

  def change do
    create table(:meta_schema_carpeta_orden) do
      add :ruta, :string, null: false
      add :orden, :integer, null: false
    end

    create unique_index(:meta_schema_carpeta_orden, [:ruta])
  end
end
