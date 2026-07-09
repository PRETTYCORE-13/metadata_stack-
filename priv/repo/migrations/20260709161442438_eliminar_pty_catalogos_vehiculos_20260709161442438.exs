defmodule MetadataApp.Repo.Migrations.EliminarPtyCatalogosVehiculos20260709161442438 do
  use Ecto.Migration

  def change do
    drop table(:pty_catalogos_vehiculos)
  end
end
