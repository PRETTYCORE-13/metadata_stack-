defmodule MetadataApp.Repo.Migrations.ReconstruirMetaFixtureClienteEquipo do
  use Ecto.Migration

  # Mismo bug que ya pasó una vez (ver 20260727194501_restaurar_metadata_fixtures_de_test.exs):
  # "eliminar catálogo" desde BC List sobre meta_fixture_cliente/equipo
  # (2026-09-10, sin querer -- parecían datos de prueba descartables,
  # pero son infraestructura real de tests: catalogo_generico_test,
  # campos_editables_test, catalogo_controller_test, catalogo_live_test,
  # meta_transicion_controller_test, identificadores_transaccionales_*,
  # parametros_catalogo_test). Esta vez el motor BC generó migraciones
  # "eliminar_meta_fixture_*" (drop_if_exists + purgar_metadata) que
  # llegaron a aplicarse en dev Y test -- se borraron sin commitear
  # (nunca llegaron al repo) en vez de dejarlas, así que esta migración
  # es la única fuente de verdad para reconstruir desde cero.
  #
  # Réplica exacta de la estructura original: crear_meta_fixture_cliente.exs
  # + crear_meta_fixture_equipo.exs + la columna de referencia agregada
  # después en agregar_campo_referencia_a_meta_fixture_cliente.exs (esas
  # migraciones YA están marcadas "up" en schema_migrations, así que
  # Ecto nunca las va a volver a correr -- hay que replicar su resultado
  # acá a mano). IF NOT EXISTS / ON CONFLICT / WHERE NOT EXISTS en todo
  # a propósito: en una base que arranca de cero (CI) estas tablas NUNCA
  # se borraron, así que esta migración también tiene que ser un no-op
  # seguro ahí.
  def change do
    create_if_not_exists table(:meta_fixture_cliente) do
      add :meta_fixture_cliente_nombre, :string, size: 100, null: false
      add :meta_fixture_cliente_edad, :integer, null: false
      add :meta_fixture_cliente_venta, :decimal, precision: 10, scale: 2, null: false
      add :meta_fixture_cliente_sucursal_id, :integer, null: true
      add :fecha_registro, :utc_datetime, null: true

      add :insert_guid, :string, size: 32, null: false
      add :update_guid, :string, size: 32, null: true
      add :delete_guid, :string, size: 32, null: true

      add :estado_id, references(:meta_schema_estados), null: true
    end

    create_if_not_exists unique_index(
                            :meta_fixture_cliente,
                            [:meta_fixture_cliente_nombre, :meta_fixture_cliente_edad, :meta_fixture_cliente_venta],
                            name: :meta_fixture_cliente_unico_index
                          )

    create_if_not_exists table(:meta_fixture_equipo) do
      add :meta_fixture_equipo_nombre_equipo, :string, size: 100, null: false
      add :fecha_registro, :utc_datetime, null: true

      add :insert_guid, :string, size: 32, null: false
      add :update_guid, :string, size: 32, null: true
      add :delete_guid, :string, size: 32, null: true

      add :estado_id, references(:meta_schema_estados), null: true
    end

    create_if_not_exists unique_index(:meta_fixture_equipo, [:meta_fixture_equipo_nombre_equipo], name: :meta_fixture_equipo_unico_index)

    flush()

    execute(
      """
      INSERT INTO meta_schema_header
        (schema_context_name, schema_context_label, schema_context_type, schema_context_nav, schema_visible, insert_guid)
      VALUES
        ('meta_fixture_cliente', 'Fixture Cliente (test)', 1, '/__test__/fixture-cliente', false, '00000000000000000000000000000f01'),
        ('meta_fixture_equipo', 'Fixture Equipo (test)', 1, '/__test__/fixture-equipo', false, '00000000000000000000000000000f02')
      ON CONFLICT (schema_context_name) WHERE delete_guid IS NULL DO NOTHING
      """,
      "DELETE FROM meta_schema_header WHERE schema_context_name IN ('meta_fixture_cliente', 'meta_fixture_equipo')"
    )

    execute(
      """
      INSERT INTO meta_schema_detail
        (meta_schema_header_id, schema_context_field, schema_context_properties, insert_guid)
      SELECT h.id, d.campo, d.propiedades::jsonb, d.guid
      FROM meta_schema_header h
      JOIN (VALUES
        ('meta_fixture_cliente', 'meta_fixture_cliente_nombre', '{"tipo":"string","etiqueta":"Nombre","orden":1,"visible":true,"editable":true,"longitud":100}', '00000000000000000000000000000f13'),
        ('meta_fixture_cliente', 'meta_fixture_cliente_edad', '{"tipo":"integer","etiqueta":"Edad","orden":2,"visible":true,"editable":true}', '00000000000000000000000000000f14'),
        ('meta_fixture_cliente', 'meta_fixture_cliente_venta', '{"tipo":"decimal","etiqueta":"Venta","orden":3,"visible":true,"editable":true,"precision":10,"escala":2}', '00000000000000000000000000000f15'),
        ('meta_fixture_cliente', 'meta_fixture_cliente_sucursal_id', '{"tipo":"referencia","catalogo":"meta_schema_branch","etiqueta":"Sucursal","orden":4,"visible":true,"editable":true,"opcional":true}', '00000000000000000000000000000f17'),
        ('meta_fixture_equipo', 'meta_fixture_equipo_nombre_equipo', '{"tipo":"string","etiqueta":"Nombre del equipo","orden":1,"visible":true,"editable":true,"longitud":100}', '00000000000000000000000000000f16')
      ) AS d(catalogo, campo, propiedades, guid) ON d.catalogo = h.schema_context_name
      WHERE h.schema_context_name IN ('meta_fixture_cliente', 'meta_fixture_equipo')
        AND NOT EXISTS (
          SELECT 1 FROM meta_schema_detail existente
          WHERE existente.meta_schema_header_id = h.id AND existente.schema_context_field = d.campo
        )
      """,
      "DELETE FROM meta_schema_detail WHERE schema_context_field LIKE 'meta_fixture_%'"
    )
  end
end
