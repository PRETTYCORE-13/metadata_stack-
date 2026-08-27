defmodule MetadataApp.Repo.Migrations.SeedPermisoCapacidadSysadminPanelControl do
  use Ecto.Migration

  # 11va capacidad de Sysadmin (ver 20260816022113, la de Ambientes, 10ma)
  # -- "Panel Control" es una pantalla nueva de esta misma entrega, no algo
  # que existiera antes bajo otro nombre -- no hace falta migrar ningún
  # grant viejo hacia acá, nadie tenía acceso a algo que no existía. Rol
  # bien acotado a propósito (pedido explícito): nadie lo hereda gratis,
  # ni siquiera "administrador" -- se asigna a mano por usuario desde la
  # pestaña Sysadmin de UsuariosEmpresaLive.
  def up do
    {1, [%{id: permiso_id}]} =
      repo().insert_all(
        "meta_schema_permiso",
        [%{recurso: "sysadmin_panel_control", accion: "leer", descripcion: "Acceso a Panel Control (Sysadmin)", insert_guid: guid()}],
        returning: [:id]
      )

    {1, [%{id: rol_id}]} =
      repo().insert_all(
        "meta_schema_rol",
        [
          %{
            empresa_id: nil,
            nombre: "acceso_sysadmin_panel_control",
            descripcion: "Acceso a Panel Control (Sysadmin)",
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
    execute("DELETE FROM meta_schema_rol WHERE nombre = 'acceso_sysadmin_panel_control' AND es_sistema = true")
    execute("DELETE FROM meta_schema_permiso WHERE recurso = 'sysadmin_panel_control'")
  end
end
