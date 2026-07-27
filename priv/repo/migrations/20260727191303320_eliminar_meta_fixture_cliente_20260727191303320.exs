defmodule MetadataApp.Repo.Migrations.EliminarMetaFixtureCliente20260727191303320 do
  use Ecto.Migration

  def change do
    drop table(:meta_fixture_cliente)
  end
end
