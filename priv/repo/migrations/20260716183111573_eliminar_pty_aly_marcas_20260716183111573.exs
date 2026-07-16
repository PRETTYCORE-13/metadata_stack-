defmodule MetadataApp.Repo.Migrations.EliminarPtyAlyMarcas20260716183111573 do
  use Ecto.Migration

  def change do
    drop table(:pty_aly_marcas)
  end
end
