defmodule MetadataAppWeb.PermisoController do
  @moduledoc """
  Catálogo de permisos (RBAC, Fase 2 Paso 6) — CRUD manual, sin auto-seed:
  cada catálogo nuevo necesita que un admin dé de alta acá su `{recurso,
  accion}` antes de poder asignarlo a un rol.
  """

  use MetadataAppWeb, :controller

  alias MetadataApp.Permissions

  plug MetadataAppWeb.Plugs.RequierePermiso,
       [recurso: "rbac_admin", accion: "leer"] when action in [:index]

  plug MetadataAppWeb.Plugs.RequierePermiso,
       [recurso: "rbac_admin", accion: "crear"] when action in [:create]

  action_fallback MetadataAppWeb.FallbackController

  def index(conn, _params) do
    json(conn, %{data: Enum.map(Permissions.listar_permisos(), &serializar/1)})
  end

  def create(conn, params) do
    with {:ok, permiso} <- Permissions.crear_permiso(params) do
      conn |> put_status(:created) |> json(%{data: serializar(permiso)})
    end
  end

  defp serializar(p), do: %{id: p.id, recurso: p.recurso, accion: p.accion, descripcion: p.descripcion}
end
