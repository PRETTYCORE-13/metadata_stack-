defmodule MetadataApp.Repo.Migrations.RegistrarMetaSchemaDetailEmpresaIdMetaFixtureCliente do
  use Ecto.Migration

  # Repite EXACTAMENTE el bug que ya se había arreglado para
  # meta_fixture_cliente_sucursal_id (ver 20260826190000): la migración
  # 20260910120200 agregó la columna física `empresa_id` "sin
  # meta_schema_detail a propósito" (mismo criterio que branch_id/
  # sales_unit_id, que tampoco están en meta_schema_detail) -- pero A
  # DIFERENCIA de esos, alguien también agregó `empresa_id` a mano al
  # `campos:` de meta_fixture_cliente.ex, violando la invariante real de
  # `CatalogoGenerador.crear_schema/4`: `campos:` se regenera ENTERO
  # desde meta_schema_detail en cada corrida de `mix gen.catalogos`.
  #
  # Encontrado real (2026-09-17): correr `mix gen.catalogos` localmente
  # borró `empresa_id` del schema regenerado (rompiendo el test R55 de
  # SPEC-SYS-1009202602) y CI viene fallando por el mismo drift desde
  # que se agregó (confirmado: los 2 runs de CI anteriores a este fix ya
  # fallaban en el mismo paso "Verificar que no haya quedado nada sin
  # commitear", ver .github/workflows/ci.yml). Con esta fila, `campos:`
  # vuelve a coincidir con meta_schema_detail y el drift desaparece.
  def change do
    execute(
      """
      INSERT INTO meta_schema_detail
        (meta_schema_header_id, schema_context_field, schema_context_properties, insert_guid)
      SELECT h.id, 'empresa_id',
        '{"tipo":"integer","etiqueta":"Empresa","orden":5,"visible":true,"editable":true,"opcional":true}'::jsonb,
        '00000000000000000000000000e1d001'
      FROM meta_schema_header h
      WHERE h.schema_context_name = 'meta_fixture_cliente'
        AND NOT EXISTS (
          SELECT 1 FROM meta_schema_detail existente
          WHERE existente.meta_schema_header_id = h.id AND existente.schema_context_field = 'empresa_id'
        )
      """,
      "DELETE FROM meta_schema_detail WHERE schema_context_field = 'empresa_id'"
    )
  end
end
