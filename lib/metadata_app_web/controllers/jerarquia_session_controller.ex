defmodule MetadataAppWeb.JerarquiaSessionController do
  use MetadataAppWeb, :controller

  alias MetadataApp.Autenticacion
  alias MetadataApp.Permissions

  # Recibe la elección de UsuarioLive.SeleccionarJerarquia (branch/
  # inventory_location obligatorios, sales_unit opcional) y la fija en
  # sesión -- mismo criterio de "nunca confiar en el id sin revalidar"
  # que EmpresaSessionController.activar/2: cada id se revalida contra
  # Autenticacion.obtener_*_de_usuario/3 (branches_de_usuario/2 etc. por
  # debajo), nunca se confía en lo que llega crudo del form.
  def activar(conn, params) do
    usuario = conn.assigns.current_scope.usuario
    empresa = conn.assigns.current_scope.empresa_activa
    return_to = get_session(conn, :usuario_return_to)
    es_administrador? = Permissions.administrador?(usuario.id, empresa.id)

    with {:ok, branch_id} <- parse_id(params["branch_id"]),
         {:ok, inventory_id} <- parse_id(params["inventory_location_id"]),
         %{} = branch <- Autenticacion.obtener_branch_de_usuario(usuario.id, empresa.id, branch_id, es_administrador?),
         %{} = inventory_location <-
           Autenticacion.obtener_inventory_location_de_usuario(usuario.id, empresa.id, branch.id, inventory_id, es_administrador?) do
      conn =
        conn
        |> delete_session(:usuario_return_to)
        |> put_session(:branch_activo_id, branch.id)
        |> put_session(:inventory_location_activo_id, inventory_location.id)

      # Sales Unit es opcional -- "" (el <option> "Ninguna") o ausente
      # significa "no operar con ninguna", no un error.
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

      redirect(conn, to: return_to || ~p"/")
    else
      _ ->
        conn
        |> put_flash(:error, "Elegí una sucursal y un almacén válidos para continuar.")
        |> redirect(to: ~p"/meta_schema_usuario/seleccionar-jerarquia")
    end
  end

  # Selector individual de la banda de pie (Fase 4, 2026-08-11) -- a
  # diferencia de activar/2 (las 3 dimensiones juntas, para la pantalla de
  # selección inicial), estos 3 cambian UNA sola dimensión sin tocar las
  # otras, mismo criterio que ya usa EmpresaSessionController.activar/2.
  # Vuelve a la página desde donde se mandó el form (Referer), no a "/" --
  # cambiar de sucursal desde el pie de una Ficha 360° tiene que dejarte
  # en esa misma Ficha, no mandarte al inicio.
  # Cambiar de sucursal (2026-08-13) también aplica el default de
  # almacén/unidad de venta DE ESA sucursal (Autenticacion.defaults_de_branch/2)
  # -- ya no queda en blanco hasta que el usuario lo elija a mano de
  # nuevo cada vez. Si esa sucursal todavía no tiene un default
  # configurado (admin no la completó todavía), simplemente no se aplica
  # nada acá -- el bloqueo real de "no puede operar sin Unidad Operativa
  # completa" vive en CatalogoGenerico.preparar_attrs_alcance/4, no en
  # este selector.
  def activar_branch(conn, %{"id" => id}) do
    usuario = conn.assigns.current_scope.usuario
    empresa = conn.assigns.current_scope.empresa_activa
    es_administrador? = Permissions.administrador?(usuario.id, empresa.id)

    with {:ok, id} <- parse_id(id),
         %{} = branch <- Autenticacion.obtener_branch_de_usuario(usuario.id, empresa.id, id, es_administrador?) do
      defaults = Autenticacion.defaults_de_branch(usuario.id, branch.id)

      conn =
        conn
        |> put_session(:branch_activo_id, branch.id)
        |> aplicar_default_de_sucursal(:inventory_location_activo_id, defaults.inventory_location)
        |> aplicar_default_de_sucursal(:sales_unit_activo_id, defaults.sales_unit)

      redirect(conn, to: pagina_de_origen(conn))
    else
      _ ->
        conn
        |> put_flash(:error, "No tienes acceso a esa sucursal.")
        |> redirect(to: pagina_de_origen(conn))
    end
  end

  defp aplicar_default_de_sucursal(conn, _clave, nil), do: conn
  defp aplicar_default_de_sucursal(conn, clave, %{id: id}), do: put_session(conn, clave, id)

  def activar_inventory_location(conn, %{"id" => id}) do
    usuario = conn.assigns.current_scope.usuario
    empresa = conn.assigns.current_scope.empresa_activa
    branch_activo = conn.assigns.current_scope.branch_activo
    es_administrador? = Permissions.administrador?(usuario.id, empresa.id)

    with %{} = branch <- branch_activo,
         {:ok, id} <- parse_id(id),
         %{} = inventory_location <-
           Autenticacion.obtener_inventory_location_de_usuario(usuario.id, empresa.id, branch.id, id, es_administrador?) do
      conn |> put_session(:inventory_location_activo_id, inventory_location.id) |> redirect(to: pagina_de_origen(conn))
    else
      _ ->
        conn
        |> put_flash(:error, "No tienes acceso a ese almacén.")
        |> redirect(to: pagina_de_origen(conn))
    end
  end

  # Único de los 3 que acepta "" (opción "Ninguna") como elección VÁLIDA
  # -- Sales Unit es opcional, apagarlo no es un error.
  def activar_sales_unit(conn, %{"id" => id}) do
    usuario = conn.assigns.current_scope.usuario
    empresa = conn.assigns.current_scope.empresa_activa
    branch_activo = conn.assigns.current_scope.branch_activo
    es_administrador? = Permissions.administrador?(usuario.id, empresa.id)

    conn =
      case {branch_activo, parse_id(id)} do
        {%{} = branch, {:ok, id}} ->
          case Autenticacion.obtener_sales_unit_de_usuario(usuario.id, empresa.id, branch.id, id, es_administrador?) do
            nil -> conn
            sales_unit -> put_session(conn, :sales_unit_activo_id, sales_unit.id)
          end

        _ ->
          delete_session(conn, :sales_unit_activo_id)
      end

    redirect(conn, to: pagina_de_origen(conn))
  end

  # get_req_header/2 en vez de conn.remote_ip o algo por el estilo -- el
  # Referer del navegador es lo único que dice "desde qué página se mandó
  # este form", y ese es justo el criterio que queremos (volver ahí). Sin
  # Referer (ej. alguien pega la URL a mano), cae a "/" como red de
  # seguridad -- nunca deja al usuario sin destino.
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
