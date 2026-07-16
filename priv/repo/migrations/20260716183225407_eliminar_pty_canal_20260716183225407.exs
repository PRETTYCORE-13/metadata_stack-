defmodule MetadataApp.Repo.Migrations.EliminarPtyCanal20260716183225407 do
  use Ecto.Migration

  def change do
    drop table(:pty_canal)
  end
end
