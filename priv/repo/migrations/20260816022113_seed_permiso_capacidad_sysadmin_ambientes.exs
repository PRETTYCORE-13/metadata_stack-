defmodule MetadataApp.Repo.Migrations.SeedPermisoCapacidadSysadminAmbientes do
  use Ecto.Migration

  # 10ma capacidad de Sysadmin (ver 20260816014352, la primera tanda de 9)
  # -- separada en su propia migración en vez de sumarse a esa, que ya
  # corrió y se desplegó: "Ambientes de Deploy" es una pantalla nueva de
  # esta misma entrega (UI/ambientes-deploy), no algo que existiera antes
  # bajo "rbac_admin"/"sysadmin_bc" -- no hace falta migrar ningún grant
  # viejo hacia acá, nadie tenía acceso a algo que no existía.
  def up do
    {1, [%{id: permiso_id}]} =
      repo().insert_all(
        "meta_schema_permiso",
        [%{recurso: "sysadmin_ambientes", accion: "leer", descripcion: "Acceso a Ambientes de Deploy (Sysadmin)", insert_guid: guid()}],
        returning: [:id]
      )

    {1, [%{id: rol_id}]} =
      repo().insert_all(
        "meta_schema_rol",
        [
          %{
            empresa_id: nil,
            nombre: "acceso_sysadmin_ambientes",
            descripcion: "Acceso a Ambientes de Deploy (Sysadmin)",
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
    execute("DELETE FROM meta_schema_rol WHERE nombre = 'acceso_sysadmin_ambientes' AND es_sistema = true")
    execute("DELETE FROM meta_schema_permiso WHERE recurso = 'sysadmin_ambientes'")
  end
end
