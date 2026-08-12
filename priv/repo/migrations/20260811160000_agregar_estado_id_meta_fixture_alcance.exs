defmodule MetadataApp.Repo.Migrations.AgregarEstadoIdMetaFixtureAlcance do
  use Ecto.Migration

  def change do
    # CatalogoGenerico.actualizar/4 lee registro.estado_id incondicionalmente
    # (todo catálogo generado real lo tiene, aunque no haya adoptado el
    # motor de estados) -- faltaba en el fixture de test de la Fase 4b.
    alter table(:meta_fixture_alcance) do
      add :estado_id, :integer
    end
  end
end
