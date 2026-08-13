defmodule MetadataApp.Repo.Migrations.AgregarFechaRegistroAMetaFixtureAlcance do
  use Ecto.Migration

  # meta_fixture_alcance (test/support/meta_fixture_alcance.ex) es un
  # catálogo hecho a mano, sin pasar por el macro MetaCatalogoGenerico --
  # por eso no recibió fecha_registro cuando esa columna se agregó a todos
  # los catálogos generados (2026-08-06). CatalogoGenerico.crear/2 la
  # estampa igual que insert_guid en CUALQUIER catálogo, así que esta
  # tabla también la necesita.
  def change do
    alter table(:meta_fixture_alcance) do
      add :fecha_registro, :utc_datetime, null: true
    end
  end
end
