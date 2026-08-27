defmodule MetadataApp.Repo.Migrations.RestaurarTablaMetaFixtureCliente do
  use Ecto.Migration

  # Réplica exacta de priv/repo/migrations/20260723220100_crear_meta_fixture_cliente.exs
  # (tabla borrada sin querer desde BC List, ver 20260727194501_restaurar_metadata_fixtures_de_test.exs).
  #
  # Nombres de archivo renombrados 2026-08-27 (bug real: el timestamp
  # original de este grupo de migraciones tenía 17 dígitos -- milisegundos
  # pegados al final para no chocar con otra generada el mismo segundo --
  # y Ecto ordena por VERSION NUMÉRICA, no por fecha calendario: un
  # timestamp de 17 dígitos siempre ordena después de cualquier timestamp
  # normal de 14, sin importar la fecha real. En una base ya migrada
  # (dev/test locales) no se nota -- ya estaban aplicadas en el orden que
  # fuera. En una base VACÍA (CI, "Migrar desde base vacía") Ecto corre
  # TODO en orden de versión ascendente: esta migración (creaba la tabla)
  # terminaba corriendo DESPUÉS de migraciones de agosto que ya esperaban
  # la tabla creada -- reventaba con "relation does not exist").
  def change do
    create table(:meta_fixture_cliente) do
      add :meta_fixture_cliente_nombre, :string, size: 100, null: false
      add :meta_fixture_cliente_edad, :integer, null: false
      add :meta_fixture_cliente_venta, :decimal, precision: 10, scale: 2, null: false

      add :insert_guid, :string, size: 32, null: false
      add :update_guid, :string, size: 32, null: true
      add :delete_guid, :string, size: 32, null: true

      add :estado_id, references(:meta_schema_estados), null: true
    end

    create unique_index(:meta_fixture_cliente, [:meta_fixture_cliente_nombre, :meta_fixture_cliente_edad, :meta_fixture_cliente_venta], name: :meta_fixture_cliente_unico_index)
  end
end
