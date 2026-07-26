defmodule MetadataAppWeb.UsuarioRolController do
  @moduledoc """
  Asignación/revocación de roles a usuarios (RBAC, Fase 2 Paso 6). La
  empresa siempre es `current_scope.empresa_activa` — nunca un parámetro
  del cliente — así que un admin solo puede asignar roles dentro de la
  empresa en la que está parado.
  """

  use MetadataAppWeb, :controller

  alias MetadataApp.Permissions

  plug MetadataAppWeb.Plugs.RequierePermiso,
       [recurso: "rbac_admin", accion: "crear"] when action in [:create]

  plug MetadataAppWeb.Plugs.RequierePermiso,
       [recurso: "rbac_admin", accion: "eliminar"] when action in [:delete]

  action_fallback MetadataAppWeb.FallbackController

  def create(conn, %{"usuario_id" => usuario_id, "rol_id" => rol_id}) do
    empresa_id = conn.assigns.current_scope.empresa_activa.id

    with {:ok, _usuario_rol} <- Permissions.asignar_rol(usuario_id, rol_id, empresa_id) do
      conn
      |> put_status(:created)
      |> json(%{data: %{usuario_id: usuario_id, rol_id: rol_id, empresa_id: empresa_id}})
    end
  end

  def delete(conn, %{"usuario_id" => usuario_id, "rol_id" => rol_id}) do
    empresa_id = conn.assigns.current_scope.empresa_activa.id

    with {:ok, _usuario_rol} <- Permissions.revocar_rol(usuario_id, rol_id, empresa_id) do
      send_resp(conn, :no_content, "")
    end
  end
end
