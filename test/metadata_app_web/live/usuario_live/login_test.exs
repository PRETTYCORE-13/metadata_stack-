defmodule MetadataAppWeb.UsuarioLive.LoginTest do
  use MetadataAppWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import MetadataApp.AutenticacionFixtures

  describe "login page" do
    test "renders login page", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/meta_schema_usuario/log-in")

      assert html =~ "Log in"
      assert html =~ "Sign up"
      assert html =~ "Log in with email"
    end
  end

  describe "usuario login - magic link" do
    test "sends magic link email when usuario exists", %{conn: conn} do
      usuario = usuario_fixture()

      {:ok, lv, _html} = live(conn, ~p"/meta_schema_usuario/log-in")

      {:ok, _lv, html} =
        form(lv, "#login_form_magic", usuario: %{email: usuario.email})
        |> render_submit()
        |> follow_redirect(conn, ~p"/meta_schema_usuario/log-in")

      assert html =~ "If your email is in our system"

      assert MetadataApp.Repo.get_by!(MetadataApp.Autenticacion.UsuarioToken, usuario_id: usuario.id).context ==
               "login"
    end

    test "does not disclose if usuario is registered", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/meta_schema_usuario/log-in")

      {:ok, _lv, html} =
        form(lv, "#login_form_magic", usuario: %{email: "idonotexist@example.com"})
        |> render_submit()
        |> follow_redirect(conn, ~p"/meta_schema_usuario/log-in")

      assert html =~ "If your email is in our system"
    end
  end

  describe "usuario login - password" do
    test "redirects if usuario logs in with valid credentials", %{conn: conn} do
      usuario = usuario_fixture() |> set_password()

      {:ok, lv, _html} = live(conn, ~p"/meta_schema_usuario/log-in")

      form =
        form(lv, "#login_form_password",
          usuario: %{email: usuario.email, password: valid_usuario_password(), remember_me: true}
        )

      conn = submit_form(form, conn)

      assert redirected_to(conn) == ~p"/"
    end

    test "redirects to login page with a flash error if credentials are invalid", %{
      conn: conn
    } do
      {:ok, lv, _html} = live(conn, ~p"/meta_schema_usuario/log-in")

      form =
        form(lv, "#login_form_password", usuario: %{email: "test@email.com", password: "123456"})

      render_submit(form, %{user: %{remember_me: true}})

      conn = follow_trigger_action(form, conn)
      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "Invalid email or password"
      assert redirected_to(conn) == ~p"/meta_schema_usuario/log-in"
    end
  end

  describe "login navigation" do
    test "redirects to registration page when the Register button is clicked", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/meta_schema_usuario/log-in")

      {:ok, _login_live, login_html} =
        lv
        |> element("main a", "Sign up")
        |> render_click()
        |> follow_redirect(conn, ~p"/meta_schema_usuario/register")

      assert login_html =~ "Register"
    end
  end

  describe "re-authentication (sudo mode)" do
    setup %{conn: conn} do
      usuario = usuario_fixture()
      %{usuario: usuario, conn: log_in_usuario(conn, usuario)}
    end

    test "shows login page with email filled in", %{conn: conn, usuario: usuario} do
      {:ok, _lv, html} = live(conn, ~p"/meta_schema_usuario/log-in")

      assert html =~ "You need to reauthenticate"
      refute html =~ "Register"
      assert html =~ "Log in with email"

      assert html =~
               ~s(<input type="email" name="usuario[email]" id="login_form_magic_email" value="#{usuario.email}")
    end
  end
end
