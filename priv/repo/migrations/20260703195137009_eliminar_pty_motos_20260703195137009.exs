defmodule MetadataApp.Repo.Migrations.EliminarPtyMotos20260703195137009 do
  use Ecto.Migration

  def change do
    drop table(:pty_motos)
  end
end
