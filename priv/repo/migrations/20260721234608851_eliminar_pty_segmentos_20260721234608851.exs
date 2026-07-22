defmodule MetadataApp.Repo.Migrations.EliminarPtySegmentos20260721234608851 do
  use Ecto.Migration

  def change do
    drop table(:pty_segmentos)
  end
end
