defmodule MetadataApp.Repo.Migrations.AgregarCampoReferenciaAMetaFixtureCliente do
  use Ecto.Migration

  # meta_fixture_cliente no tenía ningún campo tipo "referencia" -- hacía
  # falta uno real para poder probar de punta a punta el bug real
  # encontrado en dev (2026-08-26): una Consulta Ecto con una columna
  # "referencia" visible reventaba con ArgumentError al armar el filtro
  # (CatalogoLive intentaba resolver el catálogo destino de la referencia
  # sin tenerlo disponible). "meta_schema_branch" como destino porque es
  # un catálogo de sistema, siempre existe, sin depender de otro fixture.
  #
  # "opcional":true en las propiedades (bug real 2026-08-27, agregado acá
  # después): sin esto, el generador de catálogos default a `false`
  # (campo requerido) -- fixture_cliente/1 en los tests de este catálogo
  # nunca setea este campo, así que CUALQUIER fixture reventaba con
  # "no puede quedar vacío" apenas la metadata se re-generaba desde
  # cero (`mix gen.catalogos` en una base vacía, ver CI). En dev/test
  # locales no se notó porque el .ex ya compilado en disco venía de
  # ANTES de este agregado real, con opcional:true puesto a mano en algún
  # momento -- nunca se propagó a esta migración, que es la única fuente
  # de verdad real para una base que arranca de cero.
  def change do
    alter table(:meta_fixture_cliente) do
      add :meta_fixture_cliente_sucursal_id, :integer, null: true
    end

    execute(
      """
      INSERT INTO meta_schema_detail
        (meta_schema_header_id, schema_context_field, schema_context_properties, insert_guid)
      SELECT h.id, 'meta_fixture_cliente_sucursal_id',
        '{"tipo":"referencia","catalogo":"meta_schema_branch","etiqueta":"Sucursal","orden":4,"visible":true,"editable":true,"opcional":true}'::jsonb,
        '00000000000000000000000000000f17'
      FROM meta_schema_header h
      WHERE h.schema_context_name = 'meta_fixture_cliente'
        AND NOT EXISTS (
          SELECT 1 FROM meta_schema_detail existente
          WHERE existente.meta_schema_header_id = h.id AND existente.schema_context_field = 'meta_fixture_cliente_sucursal_id'
        )
      """,
      "DELETE FROM meta_schema_detail WHERE schema_context_field = 'meta_fixture_cliente_sucursal_id'"
    )
  end
end
