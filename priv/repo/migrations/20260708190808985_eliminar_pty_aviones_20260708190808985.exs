defmodule MetadataApp.Repo.Migrations.EliminarPtyAviones20260708190808985 do
  use Ecto.Migration

  def change do
    drop table(:pty_aviones)
  end
end
