defmodule MetadataApp.Repo.Migrations.EliminarPtyMotocicletas20260720201835957 do
  use Ecto.Migration

  def change do
    drop table(:pty_motocicletas)
  end
end
