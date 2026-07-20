defmodule MetadataApp.Repo.Migrations.EliminarPtyEquiposNfl20260717181624826 do
  use Ecto.Migration

  def change do
    drop table(:pty_equipos_nfl)
  end
end
