defmodule MetadataAppWeb.EmpresaSessionController do
  use MetadataAppWeb, :controller

  alias MetadataApp.Autenticacion
  alias MetadataAppWeb.UsuarioAuth

  # Nunca confiar en el id que llega del form sin revalidar contra
  # meta_schema_usuario_empresa — un usuario podría intentar activar
  # una empresa a la que no tiene acceso editando el POST a mano.
  def activar(conn, %{"id" => empresa_id}) do
    usuario = conn.assigns.current_scope.usuario
    return_to = get_session(conn, :usuario_return_to)

    case Integer.parse(empresa_id) do
      {empresa_id, ""} ->
        case Autenticacion.obtener_empresa_de_usuario(usuario.id, empresa_id) do
          nil ->
            conn
            |> put_flash(:error, "No tienes acceso a esa empresa.")
            |> redirect(to: ~p"/meta_schema_usuario/seleccionar-empresa")

          _empresa ->
            # La jerarquía permitida (branch/inventory location) es POR
            # empresa -- cambiar de empresa siempre tiene que volver a
            # resolverla (auto-activa si hay una sola opción), nunca
            # arrastrar la de la empresa anterior. No bloquea la
            # navegación si queda pendiente/vacía -- mismo criterio que
            # log_in_usuario/2, ver el comentario ahí.
            {conn, _listo_o_pendiente} =
              conn
              |> delete_session(:usuario_return_to)
              |> put_session(:empresa_activa_id, empresa_id)
              |> UsuarioAuth.activar_jerarquia_operativa(usuario.id, empresa_id)

            redirect(conn, to: return_to || pagina_de_origen(conn))
        end

      :error ->
        conn
        |> put_flash(:error, "No tienes acceso a esa empresa.")
        |> redirect(to: ~p"/meta_schema_usuario/seleccionar-empresa")
    end
  end

  # Fuera del flujo de login (return_to viene de sesión, no de acá): un
  # cambio de empresa disparado desde el selector de la banda de pie
  # vuelve a la página desde donde se mandó el form, no siempre a "/" --
  # mismo criterio que JerarquiaSessionController.pagina_de_origen/1.
  defp pagina_de_origen(conn) do
    case get_req_header(conn, "referer") do
      [referer | _] -> URI.parse(referer).path || "/"
      [] -> "/"
    end
  end
end
