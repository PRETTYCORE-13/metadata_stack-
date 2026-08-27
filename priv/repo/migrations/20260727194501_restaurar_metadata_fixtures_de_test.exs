defmodule MetadataApp.Repo.Migrations.RestaurarMetadataFixturesDeTest do
  use Ecto.Migration

  # Restaura meta_schema_header/detail para meta_fixture_cliente/equipo,
  # borrados sin querer desde BC List (2026-07-27) — son infraestructura
  # de TEST del BPB (usados por catalogo_generico_test, campos_editables_test,
  # catalogo_controller_test, catalogo_live_test, meta_transicion_controller_test),
  # no catálogos de negocio. Réplica de la metadata original (ver
  # priv/repo/migrations/20260723220000_crear_fixtures_de_test.exs).
  #
  # ON CONFLICT / WHERE NOT EXISTS a propósito: "eliminar catálogo" desde
  # BC List borra el header en vivo (no queda registrado en ninguna
  # migración) pero las migraciones de "eliminar_meta_fixture_*" SOLO
  # dropean la tabla física — en una base de test, que arranca de cero y
  # replica TODAS las migraciones en orden, el header nunca llegó a
  # borrarse. Sin este guard, esta migración fallaría acá por llave
  # duplicada.
  def change do
    execute(
      """
      INSERT INTO meta_schema_header
        (schema_context_name, schema_context_label, schema_context_type, schema_context_nav, schema_visible, insert_guid)
      VALUES
        ('meta_fixture_cliente', 'Fixture Cliente (test)', 1, '/__test__/fixture-cliente', false, '00000000000000000000000000000f01'),
        ('meta_fixture_equipo', 'Fixture Equipo (test)', 1, '/__test__/fixture-equipo', false, '00000000000000000000000000000f02')
      ON CONFLICT (schema_context_name) DO NOTHING
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
