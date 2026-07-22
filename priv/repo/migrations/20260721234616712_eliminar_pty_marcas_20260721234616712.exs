defmodule MetadataApp.Repo.Migrations.EliminarPtyMarcas20260721234616712 do
  use Ecto.Migration

  def change do
    drop table(:pty_marcas)
  end
end
