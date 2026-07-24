defmodule MetadataApp.Repo.Migrations.CrearFixturesDeTest do
  use Ecto.Migration

  # Reemplaza a pty_clientes/pty_equipos_nfl como catálogos "reales y
  # permanentes" que usaba el test suite del motor (catalogo_generico_test,
  # campos_editables_test, catalogo_controller_test,
  # meta_transicion_controller_test) — esos dos ya no existen, porque
  # ningún pty_* vive en git desde la limpieza de Git/CI-CD (2026-07-23,
  # ver docs/roadmap.md). Prefijo meta_fixture_ (no pty_) a
  # propósito: es infraestructura de TEST del BPB, no un Business Context
  # de negocio — nunca debería confundirse con algo que crea ADN, y por
  # eso SÍ se commitea (el prefijo pty_ es lo único que el .gitignore
  # excluye).
  #
  # Solo METADATA acá (meta_schema_header/detail) — a propósito NO crea la
  # tabla física ni el schema Ecto a mano: eso lo hace `mix gen.catalogos`,
  # el mismo generador que cualquier catálogo real usa, para que el
  # fixture se comporte IDÉNTICO a cualquier otro catálogo (nada de un
  # camino especial que gen.catalogos no reconozca y falle tratando de
  # regenerar algo que ya existía a mano en otro lado).
  #
  # schema_visible: false en los dos headers — no tienen que aparecer en
  # el menú real de navegación (MetaSchemaContext.listar_menu_arbol/0
  # filtra por schema_visible == true), solo son visibles/usables desde
  # BC List (listar_headers_arbol/0, sin filtro) y desde los tests.
  def change do
    execute(
      """
      INSERT INTO meta_schema_header
        (schema_context_name, schema_context_label, schema_context_type, schema_context_nav, schema_visible, insert_guid)
      VALUES
        ('meta_fixture_cliente', 'Fixture Cliente (test)', 1, '/__test__/fixture-cliente', false, '00000000000000000000000000000f01'),
        ('meta_fixture_equipo', 'Fixture Equipo (test)', 1, '/__test__/fixture-equipo', false, '00000000000000000000000000000f02')
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
        ('meta_fixture_cliente', 'meta_fixture_cliente_nombre', '{"tipo":"string","etiqueta":"Nombre","orden":1,"visible":true,"editable":true,"longitud":100}', '00000000000000000000000000000f03'),
        ('meta_fixture_cliente', 'meta_fixture_cliente_edad', '{"tipo":"integer","etiqueta":"Edad","orden":2,"visible":true,"editable":true}', '00000000000000000000000000000f04'),
        ('meta_fixture_cliente', 'meta_fixture_cliente_venta', '{"tipo":"decimal","etiqueta":"Venta","orden":3,"visible":true,"editable":true,"precision":10,"escala":2}', '00000000000000000000000000000f05'),
        ('meta_fixture_equipo', 'meta_fixture_equipo_nombre_equipo', '{"tipo":"string","etiqueta":"Nombre del equipo","orden":1,"visible":true,"editable":true,"longitud":100}', '00000000000000000000000000000f06')
      ) AS d(catalogo, campo, propiedades, guid) ON d.catalogo = h.schema_context_name
      WHERE h.schema_context_name IN ('meta_fixture_cliente', 'meta_fixture_equipo')
      """,
      "DELETE FROM meta_schema_detail WHERE schema_context_field LIKE 'meta_fixture_%'"
    )
  end
end
