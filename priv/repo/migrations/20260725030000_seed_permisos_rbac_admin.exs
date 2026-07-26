defmodule MetadataApp.Repo.Migrations.SeedPermisosRbacAdmin do
  use Ecto.Migration

  # Misma excepción que sysadmin_bc (ver 20260725020000): la API de
  # administración de RBAC en sí necesita quedar gateada desde que existe,
  # y sin sembrar estos permisos ni "administrador" podría entrar.
  def up do
    for accion <- ["leer", "crear", "editar", "eliminar"] do
      repo().insert_all("meta_schema_permiso", [
        %{
          recurso: "rbac_admin",
          accion: accion,
          insert_guid: Ecto.UUID.generate() |> String.replace("-", "")
        }
      ])
    end
  end

  def down do
    execute "DELETE FROM meta_schema_permiso WHERE recurso = 'rbac_admin'"
  end
end
