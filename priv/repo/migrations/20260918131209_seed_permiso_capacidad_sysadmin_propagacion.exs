defmodule MetadataApp.Repo.Migrations.SeedPermisoCapacidadSysadminPropagacion do
  use Ecto.Migration

  # Pantalla nueva de SPEC-SYS-1809202603 (Grupo E) -- mismo patrón que
  # 20260816022113 (Ambientes de Deploy): capacidad propia, separada de
  # la tanda original (20260816014352) porque esa ya corrió y se
  # desplegó. Verificado antes de escribir esto (mix run, en vivo) que
  # ni el rol "acceso_sysadmin_propagacion" ni el permiso
  # "sysadmin_propagacion" existían todavía.
  def up do
    {1, [%{id: permiso_id}]} =
      repo().insert_all(
        "meta_schema_permiso",
        [%{recurso: "sysadmin_propagacion", accion: "leer", descripcion: "Acceso a Propagación (Sysadmin)", insert_guid: guid()}],
        returning: [:id]
      )

    {1, [%{id: rol_id}]} =
      repo().insert_all(
        "meta_schema_rol",
        [
          %{
            empresa_id: nil,
            nombre: "acceso_sysadmin_propagacion",
            descripcion: "Acceso a Propagación (Sysadmin)",
            es_sistema: true,
            insert_guid: guid()
          }
        ],
        returning: [:id]
      )

    repo().insert_all("meta_schema_rol_permiso", [%{rol_id: rol_id, permiso_id: permiso_id, insert_guid: guid()}])
  end

  defp guid, do: Ecto.UUID.generate() |> String.replace("-", "")

  def down do
    execute("DELETE FROM meta_schema_rol WHERE nombre = 'acceso_sysadmin_propagacion' AND es_sistema = true")
    execute("DELETE FROM meta_schema_permiso WHERE recurso = 'sysadmin_propagacion'")
  end
end
