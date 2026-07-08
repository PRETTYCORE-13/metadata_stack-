defmodule MetadataApp.Repo.Migrations.EliminarPtyCarros20260708190808714 do
  use Ecto.Migration

  def change do
    drop table(:pty_carros)
  end
end
