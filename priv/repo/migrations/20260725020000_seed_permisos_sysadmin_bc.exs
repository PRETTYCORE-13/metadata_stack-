defmodule MetadataApp.Repo.Migrations.SeedPermisosSysadminBc do
  use Ecto.Migration

  # A diferencia de los permisos de catálogos pty_* (manual, uno por uno,
  # porque nacen dinámicos del wizard del BPB), acá el conjunto es fijo y
  # conocido de antemano -- sembrarlo evita que el enforcement de
  # /sysadmin/bc-list deje a todos (incluido "administrador") afuera hasta
  # que exista un CRUD de permisos (Paso 6, todavía no construido).
  def up do
    for accion <- ["leer", "crear", "editar"] do
      repo().insert_all("meta_schema_permiso", [
        %{
          recurso: "sysadmin_bc",
          accion: accion,
          insert_guid: Ecto.UUID.generate() |> String.replace("-", "")
        }
      ])
    end
  end

  def down do
    execute "DELETE FROM meta_schema_permiso WHERE recurso = 'sysadmin_bc'"
  end
end
