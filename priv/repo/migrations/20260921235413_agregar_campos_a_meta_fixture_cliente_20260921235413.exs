defmodule MetadataApp.Repo.Migrations.AgregarMetaFixtureClienteActivoAMetaFixtureCliente20260921235413 do
  use Ecto.Migration

  def change do
    alter table(:meta_fixture_cliente) do
      add :meta_fixture_cliente_activo, :boolean, null: true
    end
  end
end
