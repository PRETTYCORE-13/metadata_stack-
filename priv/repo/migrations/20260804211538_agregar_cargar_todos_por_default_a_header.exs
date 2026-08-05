defmodule MetadataApp.Repo.Migrations.AgregarCargarTodosPorDefaultAHeader do
  use Ecto.Migration

  def change do
    alter table(:meta_schema_header) do
      add :cargar_todos_por_default, :boolean, null: false, default: false
    end
  end
end
