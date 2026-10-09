defmodule MetadataApp.Repo.Migrations.RenombrarDescripcionesPermisosSysadmin do
  use Ecto.Migration

  # Las pantallas "RBAC Usuarios" y "RBAC Business Context" se llaman
  # "Permisos Usuarios" y "Permisos ADN" (menú y Permissions.capacidades_sysadmin/0).
  # La seed 20260816014352 ya guardó la descripción vieja de su rol de
  # sistema y de su permiso; esto la alinea en las bases existentes.
  @cambios [
    {"acceso_sysadmin_usuarios", "sysadmin_usuarios", "RBAC Usuarios", "Permisos Usuarios"},
    {"acceso_sysadmin_catalogos_permisos", "sysadmin_catalogos_permisos", "RBAC Business Context", "Permisos ADN"}
  ]

  def up, do: aplicar(fn {_rol, _recurso, viejo, nuevo} -> {viejo, nuevo} end)
  def down, do: aplicar(fn {_rol, _recurso, viejo, nuevo} -> {nuevo, viejo} end)

  defp aplicar(direccion) do
    for {rol, recurso, _viejo, _nuevo} = cambio <- @cambios do
      {de, a} = direccion.(cambio)
      antes = "Acceso a #{de} (Sysadmin)"
      despues = "Acceso a #{a} (Sysadmin)"

      execute(fn ->
        repo().query!("UPDATE meta_schema_rol SET descripcion = $1 WHERE nombre = $2 AND descripcion = $3", [despues, rol, antes])

        repo().query!(
          "UPDATE meta_schema_permiso SET descripcion = $1 WHERE recurso = $2 AND accion = 'leer' AND descripcion = $3",
          [despues, recurso, antes]
        )
      end)
    end
  end
end
