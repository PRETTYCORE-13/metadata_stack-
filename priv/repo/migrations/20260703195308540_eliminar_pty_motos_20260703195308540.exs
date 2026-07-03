defmodule MetadataApp.Repo.Migrations.EliminarPtyMotos20260703195308540 do
  use Ecto.Migration

  def change do
    drop table(:pty_motos)
  end
end
