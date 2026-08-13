defmodule MetadataApp.Repo.Migrations.AgregarEmpresaDefaultAUsuario do
  use Ecto.Migration

  # Jerarquía operativa activa -- "default" de Empresa (2026-08-12), a
  # pedido explícito: mismo concepto que branch_default_id/
  # sales_unit_default_id/inventory_default_id (agregados hoy más
  # temprano en meta_schema_usuario_empresa), pero acá vive en
  # meta_schema_usuario en vez de en la fila de membresía -- el default
  # de empresa dice "cuál de las N empresas a las que pertenezco es la
  # mía por default", no "dentro de esta empresa, cuál sub-recurso es
  # default" (eso sí es por-empresa, este no). nilify_all: si se borra
  # la empresa, el default se limpia solo.
  def change do
    alter table(:meta_schema_usuario) do
      add :empresa_default_id, references(:meta_schema_empresa, on_delete: :nilify_all)
    end
  end
end
