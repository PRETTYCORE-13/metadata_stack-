defmodule MetadataApp.Repo.Migrations.EliminarPty20260707173206190 do
  use Ecto.Migration

  def change do
    drop table(:pty_)
  end
end
