defmodule MetadataApp.Repo.Migrations.EliminarPtySubcanal20260716183221725 do
  use Ecto.Migration

  def change do
    drop table(:pty_subcanal)
  end
end
