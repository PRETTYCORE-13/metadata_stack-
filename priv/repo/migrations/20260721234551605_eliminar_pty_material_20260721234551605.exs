defmodule MetadataApp.Repo.Migrations.EliminarPtyMaterial20260721234551605 do
  use Ecto.Migration

  def change do
    drop table(:pty_material)
  end
end
