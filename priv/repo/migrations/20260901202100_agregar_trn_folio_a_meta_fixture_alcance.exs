defmodule MetadataApp.Repo.Migrations.AgregarTrnFolioAMetaFixtureAlcance do
  use Ecto.Migration

  # SPEC-SYS-0109202601 (Administrador de Folios) — extiende el fixture
  # de Alcance de Datos para poder probar
  # MetadataApp.IdentificadoresTransaccionales de punta a punta vía
  # CatalogoGenerico.crear/2 real (necesita un catálogo transaccional
  # con alcance Y folio a la vez), sin tener que generar un catálogo
  # BC nuevo completo solo para el test. `subtipo_transaccion` también
  # se agrega acá para poder probar la resolución de perfil (design.md
  # §3.1) con y sin subtipo.
  def change do
    alter table(:meta_fixture_alcance) do
      add :trn, :string, size: 23, null: true
      add :ulid, :string, size: 26, null: true
      add :folio_serie, :string, size: 4, null: true
      add :folio_numero, :integer, null: true
      add :subtipo_transaccion, :integer, null: true
    end
  end
end
