defmodule MetadataApp.Repo.Migrations.EliminarPtyMarcas do
  use Ecto.Migration

  def change do
    drop table(:pty_marcas)
  end
end
