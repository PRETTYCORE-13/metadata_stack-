defmodule MetadataApp.Repo.Migrations.AgregarTrnFolioAMetaFixtureAlcance do
  use Ecto.Migration

  # Extiende el fixture de Alcance de Datos (Fase 4a/4b) para poder
  # probar MetadataApp.Folio de punta a punta vía CatalogoGenerico.crear/2
  # real (necesita un catálogo que sea transaccional Y tenga alcance
  # habilitado a la vez, ver Header.validar_requiere_folio/1) sin tener
  # que generar un catálogo nuevo completo solo para el test.
  def change do
    alter table(:meta_fixture_alcance) do
      add :trn, :string, size: 23, null: true
      add :ulid, :string, size: 26, null: true
      add :folio, :string, size: 40, null: true
    end
  end
end
