defmodule MetadataApp.Repo.Migrations.EliminarPtyCamiones20260706190439836 do
  use Ecto.Migration

  def change do
    drop table(:pty_camiones)
  end
end
