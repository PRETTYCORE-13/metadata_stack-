defmodule MetadataApp.Repo.Migrations.EliminarPtyMotos20260707181451394 do
  use Ecto.Migration

  def change do
    drop_if_exists table(:pty_motos)
  end
end
