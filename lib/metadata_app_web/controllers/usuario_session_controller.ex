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
  defp create(conn, %{"usuario" => %{"token" => token} = usuario_params}, info) do
    case Autenticacion.login_usuario_by_magic_link(token) do
      {:ok, {usuario, tokens_to_disconnect}} ->
        UsuarioAuth.disconnect_sessions(tokens_to_disconnect)

        conn
        |> put_flash(:info, info)
        |> UsuarioAuth.log_in_usuario(usuario, usuario_params)

      _ ->
        conn
        |> put_flash(:error, "The link is invalid or it has expired.")
        |> redirect(to: ~p"/meta_schema_usuario/log-in")
    end
  end

  # email + password login
  defp create(conn, %{"usuario" => usuario_params}, info) do
    %{"email" => email, "password" => password} = usuario_params

    if usuario = Autenticacion.get_usuario_by_email_and_password(email, password) do
      conn
      |> put_flash(:info, info)
      |> UsuarioAuth.log_in_usuario(usuario, usuario_params)
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
    {:ok, {_usuario, expired_tokens}} = Autenticacion.update_usuario_password(usuario, usuario_params)

    # disconnect all existing LiveViews with old sessions
    UsuarioAuth.disconnect_sessions(expired_tokens)

    conn
    |> put_session(:usuario_return_to, ~p"/meta_schema_usuario/settings")
    |> create(params, "Password updated successfully!")
  end

  def delete(conn, _params) do
    conn
    |> put_flash(:info, "Logged out successfully.")
    |> UsuarioAuth.log_out_usuario()
  end
end
