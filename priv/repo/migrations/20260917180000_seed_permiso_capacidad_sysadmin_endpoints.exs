defmodule MetadataApp.Repo.Migrations.SeedPermisoCapacidadSysadminEndpoints do
  use Ecto.Migration

  # 13va capacidad de Sysadmin (ver 20260826210100, Panel Control, la
  # 11va) -- "Endpoints" (SPEC-SYS-1009202602) hasta acá compartía el
  # gate de acceso con Business Process Builder (`on_mount
  # {"sysadmin_bc", "editar"}` en EndpointsLive) porque nació DENTRO de
  # esa sección. A pedido explícito del usuario ("en esta pantalla
  # también debe estar Endpoint para permisos", viendo la pestaña
  # Sysadmin de UsuariosEmpresaLive con Business Process Builder pero
  # sin Endpoints como switch propio) se separa en un recurso propio,
  # mismo patrón que ya se le aplicó a Tepache en 20260816014352.
  #
  # A diferencia de Panel Control (pantalla nueva, nadie tenía acceso
  # previo), acá SÍ hay que migrar: cualquier rol que hoy tenga
  # "acceso_sysadmin_bc" (o el permiso sysadmin_bc/editar directo)
  # concedido ya puede entrar a Endpoints -- se le suma el permiso
  # nuevo para que nadie pierda acceso que ya tenía al correr esta
  # migración.
  def up do
    {1, [%{id: permiso_id}]} =
      repo().insert_all(
        "meta_schema_permiso",
        [%{recurso: "sysadmin_endpoints", accion: "leer", descripcion: "Acceso a Endpoints (Sysadmin)", insert_guid: guid()}],
        returning: [:id]
      )

    {1, [%{id: rol_id}]} =
      repo().insert_all(
        "meta_schema_rol",
        [
          %{
            empresa_id: nil,
            nombre: "acceso_sysadmin_endpoints",
            descripcion: "Acceso a Endpoints (Sysadmin)",
            es_sistema: true,
            insert_guid: guid()
          }
        ],
        returning: [:id]
      )

    repo().insert_all("meta_schema_rol_permiso", [%{rol_id: rol_id, permiso_id: permiso_id, insert_guid: guid()}])

    migrar_grants_existentes(permiso_id)
  end

  # Mismo criterio que migrar_grants_existentes/2 de 20260816014352:
  # cualquier rol (que no sea "administrador", ya cubierto por bypass)
  # que hoy tenga sysadmin_bc/editar concedido recibe acá el permiso
  # nuevo de Endpoints.
  defp migrar_grants_existentes(permiso_nuevo_id) do
    %{rows: roles_con_bc_editar} =
      repo().query!("""
      SELECT DISTINCT rp.rol_id
      FROM meta_schema_rol_permiso rp
      JOIN meta_schema_permiso p ON p.id = rp.permiso_id AND p.delete_guid IS NULL
      JOIN meta_schema_rol r ON r.id = rp.rol_id AND r.delete_guid IS NULL
      WHERE p.recurso = 'sysadmin_bc' AND p.accion = 'editar' AND rp.delete_guid IS NULL
        AND NOT (r.es_sistema = true AND r.nombre = 'administrador')
      """)

    for [rol_id] <- roles_con_bc_editar do
      repo().query!(
        """
        INSERT INTO meta_schema_rol_permiso (rol_id, permiso_id, insert_guid)
        VALUES ($1, $2, $3)
        ON CONFLICT DO NOTHING
        """,
        [rol_id, permiso_nuevo_id, guid()]
      )
    end
  end

  defp guid, do: Ecto.UUID.generate() |> String.replace("-", "")

  def down do
    execute("DELETE FROM meta_schema_rol WHERE nombre = 'acceso_sysadmin_endpoints' AND es_sistema = true")
    execute("DELETE FROM meta_schema_permiso WHERE recurso = 'sysadmin_endpoints'")
  end
end
