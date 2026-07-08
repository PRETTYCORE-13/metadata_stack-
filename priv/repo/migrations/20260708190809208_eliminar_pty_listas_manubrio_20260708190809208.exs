defmodule MetadataApp.Repo.Migrations.EliminarPtyListasManubrio20260708190809208 do
  use Ecto.Migration

  def change do
    drop table(:pty_listas_manubrio)
  end
end
