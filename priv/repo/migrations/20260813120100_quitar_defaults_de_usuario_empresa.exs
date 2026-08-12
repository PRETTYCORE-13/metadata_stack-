defmodule MetadataApp.Repo.Migrations.QuitarDefaultsDeUsuarioEmpresa do
  use Ecto.Migration

  # El default de almacén/unidad de venta pasa a vivir en
  # meta_schema_usuario_branch (por SUCURSAL, no por empresa) -- ver
  # 20260813120000_agregar_defaults_a_usuario_branch.exs. branch_default_id
  # se queda acá, ese sí es por empresa.
  def change do
    alter table(:meta_schema_usuario_empresa) do
      remove :sales_unit_default_id
      remove :inventory_default_id
    end
  end
end
