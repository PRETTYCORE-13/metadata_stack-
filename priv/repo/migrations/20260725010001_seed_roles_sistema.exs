defmodule MetadataApp.Repo.Migrations.SeedRolesSistema do
  use Ecto.Migration

  # Roles globales (empresa_id: nil), disponibles para cualquier empresa sin
  # sembrado adicional. "administrador" no depende de tener cada permiso
  # linkeado en meta_schema_rol_permiso (ver Permissions.can?/3): se
  # reconoce por es_sistema + nombre y pasa siempre. "consulta" sí se arma
  # a mano asignándole los permisos "leer" que corresponda por catálogo.
  def up do
    for nombre <- ["administrador", "consulta"] do
      repo().insert_all("meta_schema_rol", [
        %{
          nombre: nombre,
          es_sistema: true,
          insert_guid: Ecto.UUID.generate() |> String.replace("-", "")
        }
      ])
    end
  end

  def down do
    execute "DELETE FROM meta_schema_rol WHERE nombre IN ('administrador', 'consulta') AND empresa_id IS NULL"
  end
end
