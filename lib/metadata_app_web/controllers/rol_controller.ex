defmodule MetadataAppWeb.RolController do
  @moduledoc """
  Administración de roles (RBAC, Fase 2 Paso 6). Todo resuelto contra
  `current_scope.empresa_activa` — nunca contra un `empresa_id` de
  parámetro del cliente. Roles de sistema (`es_sistema: true`) no se editan
  ni se eliminan acá (`MetadataApp.Permissions.actualizar_rol/2` y
  `eliminar_rol/1` los rechazan).
  """

  use MetadataAppWeb, :controller

  alias MetadataApp.Permissions

  plug MetadataAppWeb.Plugs.RequierePermiso,
       [recurso: "rbac_admin", accion: "leer"] when action in [:index, :show]

  plug MetadataAppWeb.Plugs.RequierePermiso,
       [recurso: "rbac_admin", accion: "crear"] when action in [:create]

  plug MetadataAppWeb.Plugs.RequierePermiso,
       [recurso: "rbac_admin", accion: "editar"] when action in [:update, :reemplazar_permisos]

  plug MetadataAppWeb.Plugs.RequierePermiso,
       [recurso: "rbac_admin", accion: "eliminar"] when action in [:delete]

  action_fallback MetadataAppWeb.FallbackController

  def index(conn, _params) do
    roles = Permissions.listar_roles(empresa_id!(conn))
    json(conn, %{data: Enum.map(roles, &serializar/1)})
  end

  def show(conn, %{"id" => id}) do
    with {:ok, rol} <- Permissions.obtener_rol(id) do
      json(conn, %{data: serializar(rol)})
    end
  end

  def create(conn, params) do
    attrs = Map.put(params, "empresa_id", empresa_id!(conn))

    with {:ok, rol} <- Permissions.crear_rol(attrs) do
      conn |> put_status(:created) |> json(%{data: serializar(rol)})
    end
  end

  def update(conn, %{"id" => id} = params) do
    with {:ok, rol} <- Permissions.obtener_rol(id),
         {:ok, actualizado} <- Permissions.actualizar_rol(rol, params) do
      json(conn, %{data: serializar(actualizado)})
    end
  end

  def delete(conn, %{"id" => id}) do
    with {:ok, rol} <- Permissions.obtener_rol(id),
         {:ok, _} <- Permissions.eliminar_rol(rol) do
      send_resp(conn, :no_content, "")
    end
  end

  @doc "PUT (no PATCH): la lista de permiso_ids reemplaza por completo la anterior."
  def reemplazar_permisos(conn, %{"id" => id, "permiso_ids" => permiso_ids}) do
    with :ok <- Permissions.reemplazar_permisos_de_rol(id, permiso_ids) do
      json(conn, %{data: %{rol_id: id, permiso_ids: permiso_ids}})
    end
  end

  defp empresa_id!(conn), do: conn.assigns.current_scope.empresa_activa.id

  defp serializar(rol) do
    %{
      id: rol.id,
      nombre: rol.nombre,
      descripcion: rol.descripcion,
      es_sistema: rol.es_sistema,
      empresa_id: rol.empresa_id
    }
  end
end
