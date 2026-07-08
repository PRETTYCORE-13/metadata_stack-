defmodule MetadataApp.Repo.Migrations.EliminarPtyCamiones20260708190808913 do
  use Ecto.Migration

  def change do
    drop table(:pty_camiones)
  end
end
