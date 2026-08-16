defmodule MetadataAppWeb.UnidadOperativaSessionController do
  use MetadataAppWeb, :controller

  alias MetadataApp.Autenticacion
  alias MetadataApp.Permissions

  # Contraparte de MetadataAppWeb.CambiarUnidadOperativaModal (2026-08-15,
  # UI/cambio-unidad-operativa) -- a diferencia de EmpresaSessionController
  # y JerarquiaSessionController (una dimensión a la vez, pensados para el
  # selector viejo de la banda de pie que se auto-enviaba en cada <select>),
  # este activa las 4 dimensiones JUNTAS en un solo POST, recién al
  # aceptar el modal. Mismo criterio de "nunca confiar en el id sin
  # revalidar" que esos dos -- cada id se revalida contra el universo
  # operable del usuario, empresa incluida, antes de tocar la sesión.
  def activar(conn, params) do
    usuario = conn.assigns.current_scope.usuario
    return_to = get_session(conn, :usuario_return_to)

    with {:ok, empresa_id} <- parse_id(params["empresa_id"]),
         %{} = empresa <- Autenticacion.obtener_empresa_de_usuario(usuario.id, empresa_id),
         es_administrador? = Permissions.administrador?(usuario.id, empresa.id),
         {:ok, branch_id} <- parse_id(params["branch_id"]),
         %{} = branch <- Autenticacion.obtener_branch_de_usuario(usuario.id, empresa.id, branch_id, es_administrador?),
         {:ok, inventory_id} <- parse_id(params["inventory_location_id"]),
         %{} = inventory_location <-
           Autenticacion.obtener_inventory_location_de_usuario(usuario.id, empresa.id, branch.id, inventory_id, es_administrador?) do
      conn =
        conn
        |> delete_session(:usuario_return_to)
        |> put_session(:empresa_activa_id, empresa.id)
        |> put_session(:branch_activo_id, branch.id)
        |> put_session(:inventory_location_activo_id, inventory_location.id)

      # Sales Unit es opcional -- "" (el <option> "Ninguna") o ausente
      # significa "no operar con ninguna", no un error, mismo criterio que
      # JerarquiaSessionController.activar/2.
      conn =
        case parse_id(params["sales_unit_id"]) do
          {:ok, sales_unit_id} ->
            case Autenticacion.obtener_sales_unit_de_usuario(usuario.id, empresa.id, branch.id, sales_unit_id, es_administrador?) do
              nil -> delete_session(conn, :sales_unit_activo_id)
              sales_unit -> put_session(conn, :sales_unit_activo_id, sales_unit.id)
            end

          :error ->
            delete_session(conn, :sales_unit_activo_id)
        end

      redirect(conn, to: return_to || pagina_de_origen(conn))
    else
      _ ->
        conn
        |> put_flash(:error, "No se pudo cambiar la Unidad Operativa -- revisá la selección.")
        |> redirect(to: pagina_de_origen(conn))
    end
  end

  defp pagina_de_origen(conn) do
    case get_req_header(conn, "referer") do
      [referer | _] -> URI.parse(referer).path || "/"
      [] -> "/"
    end
  end

  defp parse_id(nil), do: :error
  defp parse_id(""), do: :error

  defp parse_id(valor) do
    case Integer.parse(valor) do
      {id, ""} -> {:ok, id}
      _ -> :error
    end
  end
end
