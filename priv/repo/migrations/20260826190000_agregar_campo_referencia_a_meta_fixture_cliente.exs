defmodule MetadataApp.Repo.Migrations.AgregarCampoReferenciaAMetaFixtureCliente do
  use Ecto.Migration

  # meta_fixture_cliente no tenía ningún campo tipo "referencia" -- hacía
  # falta uno real para poder probar de punta a punta el bug real
  # encontrado en dev (2026-08-26): una Consulta Ecto con una columna
  # "referencia" visible reventaba con ArgumentError al armar el filtro
  # (CatalogoLive intentaba resolver el catálogo destino de la referencia
  # sin tenerlo disponible). "meta_schema_branch" como destino porque es
  # un catálogo de sistema, siempre existe, sin depender de otro fixture.
  def change do
    alter table(:meta_fixture_cliente) do
      add :meta_fixture_cliente_sucursal_id, :integer, null: true
    end

    execute(
      """
      INSERT INTO meta_schema_detail
        (meta_schema_header_id, schema_context_field, schema_context_properties, insert_guid)
      SELECT h.id, 'meta_fixture_cliente_sucursal_id',
        '{"tipo":"referencia","catalogo":"meta_schema_branch","etiqueta":"Sucursal","orden":4,"visible":true,"editable":true}'::jsonb,
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
