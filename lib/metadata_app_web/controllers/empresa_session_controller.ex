defmodule MetadataAppWeb.EmpresaSessionController do
  use MetadataAppWeb, :controller

  alias MetadataApp.Autenticacion

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
            |> put_flash(:error, "No tenés acceso a esa empresa.")
            |> redirect(to: ~p"/meta_schema_usuario/seleccionar-empresa")

          _empresa ->
            conn
            |> delete_session(:usuario_return_to)
            |> put_session(:empresa_activa_id, empresa_id)
            |> redirect(to: return_to || ~p"/")
        end

      :error ->
        conn
        |> put_flash(:error, "No tenés acceso a esa empresa.")
        |> redirect(to: ~p"/meta_schema_usuario/seleccionar-empresa")
    end
  end
end
