defmodule MetadataAppWeb.UsuarioLive.ConfirmationTest do
  use MetadataAppWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import MetadataApp.AutenticacionFixtures

  alias MetadataApp.Autenticacion

  setup do
    %{unconfirmed_usuario: unconfirmed_usuario_fixture(), confirmed_usuario: usuario_fixture()}
  end

  describe "Confirm usuario" do
    test "renders confirmation page for unconfirmed usuario", %{conn: conn, unconfirmed_usuario: usuario} do
      token =
        extract_usuario_token(fn url ->
          Autenticacion.deliver_login_instructions(usuario, url)
        end)

      {:ok, _lv, html} = live(conn, ~p"/meta_schema_usuario/log-in/#{token}")
      assert html =~ "Confirm and stay logged in"
    end

    test "renders login page for confirmed usuario", %{conn: conn, confirmed_usuario: usuario} do
      token =
        extract_usuario_token(fn url ->
          Autenticacion.deliver_login_instructions(usuario, url)
        end)

      {:ok, _lv, html} = live(conn, ~p"/meta_schema_usuario/log-in/#{token}")
      refute html =~ "Confirm my account"
      assert html =~ "Keep me logged in on this device"
    end

    test "renders login page for already logged in usuario", %{conn: conn, confirmed_usuario: usuario} do
      conn = log_in_usuario(conn, usuario)

      token =
        extract_usuario_token(fn url ->
          Autenticacion.deliver_login_instructions(usuario, url)
        end)

      {:ok, _lv, html} = live(conn, ~p"/meta_schema_usuario/log-in/#{token}")
      refute html =~ "Confirm my account"
      assert html =~ "Log in"
    end

    test "confirms the given token once", %{conn: conn, unconfirmed_usuario: usuario} do
      token =
        extract_usuario_token(fn url ->
          Autenticacion.deliver_login_instructions(usuario, url)
        end)

      {:ok, lv, _html} = live(conn, ~p"/meta_schema_usuario/log-in/#{token}")

      form = form(lv, "#confirmation_form", %{"usuario" => %{"token" => token}})
      render_submit(form)

      conn = follow_trigger_action(form, conn)

      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~
               "Usuario confirmed successfully"

      assert Autenticacion.get_usuario!(usuario.id).confirmed_at
      # we are logged in now
      assert get_session(conn, :usuario_token)
      assert redirected_to(conn) == ~p"/"

      # log out, new conn
      conn = build_conn()

      {:ok, _lv, html} =
        live(conn, ~p"/meta_schema_usuario/log-in/#{token}")
        |> follow_redirect(conn, ~p"/meta_schema_usuario/log-in")

      assert html =~ "Magic link is invalid or it has expired"
    end

    test "logs confirmed usuario in without changing confirmed_at", %{
      conn: conn,
      confirmed_usuario: usuario
    } do
      token =
        extract_usuario_token(fn url ->
          Autenticacion.deliver_login_instructions(usuario, url)
        end)

      {:ok, lv, _html} = live(conn, ~p"/meta_schema_usuario/log-in/#{token}")

      form = form(lv, "#login_form", %{"usuario" => %{"token" => token}})
      render_submit(form)

      conn = follow_trigger_action(form, conn)

      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~
               "Welcome back!"

      assert Autenticacion.get_usuario!(usuario.id).confirmed_at == usuario.confirmed_at

      # log out, new conn
      conn = build_conn()

      {:ok, _lv, html} =
        live(conn, ~p"/meta_schema_usuario/log-in/#{token}")
        |> follow_redirect(conn, ~p"/meta_schema_usuario/log-in")

      assert html =~ "Magic link is invalid or it has expired"
    end

    test "raises error for invalid token", %{conn: conn} do
      {:ok, _lv, html} =
        live(conn, ~p"/meta_schema_usuario/log-in/invalid-token")
        |> follow_redirect(conn, ~p"/meta_schema_usuario/log-in")

      assert html =~ "Magic link is invalid or it has expired"
    end
  end
end
