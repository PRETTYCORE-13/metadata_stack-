defmodule MetadataApp.Repo.Migrations.EliminarPtyMotos do
  use Ecto.Migration

  def change do
    drop table(:pty_motos)
  end
end
