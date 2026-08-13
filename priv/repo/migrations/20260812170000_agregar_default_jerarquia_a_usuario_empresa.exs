defmodule MetadataApp.Repo.Migrations.AgregarDefaultJerarquiaAUsuarioEmpresa do
  use Ecto.Migration

  # Jerarquía operativa activa -- "default" (2026-08-12): distinto de
  # "permitido" (usuario_branch/usuario_sales_unit/usuario_inventory_location,
  # el universo que el usuario puede operar) y de "activo" (Scope,
  # session-scoped, lo que está eligiendo AHORA) -- esto es lo que un
  # admin PRE-CONFIGURA para que el login lo auto-active, incluso cuando
  # el usuario tiene 2+ opciones permitidas (antes solo se auto-activaba
  # con exactamente 1, ver Autenticacion.resolver_jerarquia_operativa/3).
  # Vive en meta_schema_usuario_empresa (no en usuario_branch etc.)
  # porque el default es POR EMPRESA, igual que la asignación misma --
  # un admin de dos empresas puede tener sucursales distintas de default
  # en cada una. nilify_all: si se borra la sucursal/almacén/unidad que
  # era default, el default simplemente se limpia (no arrastra un id
  # muerto) -- mismo criterio de "revalidar en cada hidratación" que ya
  # usa UsuarioAuth.hidratar_branch_activo/4.
  def change do
    alter table(:meta_schema_usuario_empresa) do
      add :branch_default_id, references(:meta_schema_branch, on_delete: :nilify_all)
      add :sales_unit_default_id, references(:meta_schema_sales_unit, on_delete: :nilify_all)
      add :inventory_default_id, references(:meta_schema_inventory_location, on_delete: :nilify_all)
    end
  end
end
