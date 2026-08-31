defmodule MetadataApp.Repo.Migrations.SeedPermisoCapacidadSysadminNdt do
  use Ecto.Migration

  # NDT Config, pantalla nueva de esta misma entrega (mismo criterio que
  # 20260816022113, "Ambientes de Deploy") -- recurso propio, sin migrar
  # ningún grant viejo (nadie tenía acceso a algo que no existía).
  def up do
    {1, [%{id: permiso_id}]} =
      repo().insert_all(
        "meta_schema_permiso",
        [%{recurso: "sysadmin_ndt", accion: "leer", descripcion: "Acceso a NDT Config (Sysadmin)", insert_guid: guid()}],
        returning: [:id]
      )

    {1, [%{id: rol_id}]} =
      repo().insert_all(
        "meta_schema_rol",
        [
          %{
            empresa_id: nil,
            nombre: "acceso_sysadmin_ndt",
            descripcion: "Acceso a NDT Config (Sysadmin)",
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
    execute("DELETE FROM meta_schema_rol WHERE nombre = 'acceso_sysadmin_ndt' AND es_sistema = true")
    execute("DELETE FROM meta_schema_permiso WHERE recurso = 'sysadmin_ndt'")
  end
end
