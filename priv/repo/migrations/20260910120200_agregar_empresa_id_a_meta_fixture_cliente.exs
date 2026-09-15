defmodule MetadataApp.Repo.Migrations.AgregarEmpresaIdAMetaFixtureCliente do
  use Ecto.Migration

  # meta_fixture_cliente no tenía ninguna columna `empresa_id` real --
  # hacía falta una para poder probar de punta a punta (SPEC-SYS-1009202602,
  # Grupo C) el nuevo alcance {:empresa_fija, empresa_id} de
  # MetaConsultas.aplicar_alcance_de_datos/4 contra una columna real, sin
  # depender de un catálogo generado en dev (fuera de este repo). Sin
  # meta_schema_detail a propósito -- este alcance no necesita que el
  # campo sea "visible"/"referencia", solo que exista como columna física
  # (mismo criterio que branch_id/sales_unit_id/etc. de con_columna/con_columna_alcance).
  def change do
    alter table(:meta_fixture_cliente) do
      add :empresa_id, :integer, null: true
    end
  end
end
