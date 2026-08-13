defmodule MetadataAppWeb.UsuarioSessionController do
  use MetadataAppWeb, :controller

  alias MetadataApp.Autenticacion
  alias MetadataAppWeb.UsuarioAuth

  def create(conn, %{"_action" => "confirmed"} = params) do
    create(conn, params, "Usuario confirmed successfully.")
  end

  def create(conn, params) do
    create(conn, params, "Welcome back!")
  end

  # magic link login
  defp create(conn, %{"usuario" => %{"token" => token}}, info) do
    case Autenticacion.login_usuario_by_magic_link(token) do
      {:ok, {usuario, tokens_to_disconnect}} ->
        UsuarioAuth.disconnect_sessions(tokens_to_disconnect)

        conn
        |> put_flash(:info, info)
        |> UsuarioAuth.log_in_usuario(usuario)

      _ ->
        conn
        |> put_flash(:error, "The link is invalid or it has expired.")
        |> redirect(to: ~p"/meta_schema_usuario/log-in")
    end
  end

  # email + password login
  defp create(conn, %{"usuario" => %{"email" => email, "password" => password}}, info) do

    if usuario = Autenticacion.get_usuario_by_email_and_password(email, password) do
      conn
      |> put_flash(:info, info)
      |> UsuarioAuth.log_in_usuario(usuario)
    else
      # In order to prevent user enumeration attacks, don't disclose whether the email is registered.
      conn
      |> put_flash(:error, "Invalid email or password")
      |> put_flash(:email, String.slice(email, 0, 160))
      |> redirect(to: ~p"/meta_schema_usuario/log-in")
    end
  end

  def update_password(conn, %{"usuario" => usuario_params} = params) do
    usuario = conn.assigns.current_scope.usuario
    true = Autenticacion.sudo_mode?(usuario)

    # El submit final acá es un POST nativo del navegador (phx-trigger-action
    # en UsuarioLive.Settings), no un evento LiveView — el LiveView ya validó
    # antes de disparar el trigger, pero eso no es una garantía absoluta del
    # lado servidor (ej. autofill del navegador puede no disparar phx-change
    # a tiempo). Manejar {:error, _} acá evita un 500 crudo si igual llega
    # algo inválido, en vez de asumir que siempre va a ser {:ok, _}.
    case Autenticacion.update_usuario_password(usuario, usuario_params) do
      {:ok, {_usuario, expired_tokens}} ->
        UsuarioAuth.disconnect_sessions(expired_tokens)

        conn
        |> put_session(:usuario_return_to, ~p"/meta_schema_usuario/settings")
        |> create(params, "Password updated successfully!")

      {:error, _changeset} ->
        conn
        |> put_flash(:error, "No se pudo actualizar la contraseña — revisá que tenga al menos 12 caracteres y que la confirmación coincida.")
        |> redirect(to: ~p"/meta_schema_usuario/settings")
    end
  end

  def delete(conn, _params) do
    conn
    |> put_flash(:info, "Logged out successfully.")
    |> UsuarioAuth.log_out_usuario()
  end
end
