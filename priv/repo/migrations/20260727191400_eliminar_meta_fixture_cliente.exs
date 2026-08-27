defmodule MetadataApp.Repo.Migrations.EliminarMetaFixtureCliente do
  use Ecto.Migration

  def change do
    drop table(:meta_fixture_cliente)
  end
end
