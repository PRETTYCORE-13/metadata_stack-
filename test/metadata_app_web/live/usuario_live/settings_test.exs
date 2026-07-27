defmodule MetadataAppWeb.UsuarioLive.SettingsTest do
  use MetadataAppWeb.ConnCase, async: true

  alias MetadataApp.Autenticacion
  import Phoenix.LiveViewTest
  import MetadataApp.AutenticacionFixtures

  describe "Settings page" do
    test "renders settings page", %{conn: conn} do
      {:ok, _lv, html} =
        conn
        |> log_in_usuario(usuario_fixture())
        |> live(~p"/meta_schema_usuario/settings")

      assert html =~ "Change Email"
      assert html =~ "Save Password"
    end

    test "redirects if usuario is not logged in", %{conn: conn} do
      assert {:error, redirect} = live(conn, ~p"/meta_schema_usuario/settings")

      assert {:redirect, %{to: path, flash: flash}} = redirect
      assert path == ~p"/meta_schema_usuario/log-in"
      assert %{"error" => "You must log in to access this page."} = flash
    end

    test "redirects if usuario is not in sudo mode", %{conn: conn} do
      {:ok, conn} =
        conn
        |> log_in_usuario(usuario_fixture(),
          token_authenticated_at: DateTime.add(DateTime.utc_now(:second), -11, :minute)
        )
        |> live(~p"/meta_schema_usuario/settings")
        |> follow_redirect(conn, ~p"/meta_schema_usuario/log-in")

      assert conn.resp_body =~ "You must re-authenticate to access this page."
    end
  end

  describe "update alias form" do
    setup %{conn: conn} do
      usuario = usuario_fixture()
      %{conn: log_in_usuario(conn, usuario), usuario: usuario}
    end

    test "updates the usuario alias", %{conn: conn, usuario: usuario} do
      {:ok, lv, _html} = live(conn, ~p"/meta_schema_usuario/settings")

      result =
        lv
        |> form("#alias_form", %{"usuario" => %{"alias" => "Uriel"}})
        |> render_submit()

      assert result =~ "Alias actualizado."
      assert Autenticacion.get_usuario!(usuario.id).alias == "Uriel"
    end

    test "renders errors with an alias too long (phx-change)", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/meta_schema_usuario/settings")

      result =
        lv
        |> element("#alias_form")
        |> render_change(%{"usuario" => %{"alias" => String.duplicate("a", 41)}})

      assert result =~ "should be at most 40 character"
    end
  end

  describe "update email form" do
    setup %{conn: conn} do
      usuario = usuario_fixture()
      %{conn: log_in_usuario(conn, usuario), usuario: usuario}
    end

    test "updates the usuario email", %{conn: conn, usuario: usuario} do
      new_email = unique_usuario_email()

      {:ok, lv, _html} = live(conn, ~p"/meta_schema_usuario/settings")

      result =
        lv
        |> form("#email_form", %{
          "usuario" => %{"email" => new_email}
        })
        |> render_submit()

      assert result =~ "A link to confirm your email"
      assert Autenticacion.get_usuario_by_email(usuario.email)
    end

    test "renders errors with invalid data (phx-change)", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/meta_schema_usuario/settings")

      result =
        lv
        |> element("#email_form")
        |> render_change(%{
          "action" => "update_email",
          "usuario" => %{"email" => "with spaces"}
        })

      assert result =~ "Change Email"
      assert result =~ "must have the @ sign and no spaces"
    end

    test "renders errors with invalid data (phx-submit)", %{conn: conn, usuario: usuario} do
      {:ok, lv, _html} = live(conn, ~p"/meta_schema_usuario/settings")

      result =
        lv
        |> form("#email_form", %{
          "usuario" => %{"email" => usuario.email}
        })
        |> render_submit()

      assert result =~ "Change Email"
      assert result =~ "did not change"
    end
  end

  describe "update password form" do
    setup %{conn: conn} do
      usuario = usuario_fixture()
      %{conn: log_in_usuario(conn, usuario), usuario: usuario}
    end

    test "updates the usuario password", %{conn: conn, usuario: usuario} do
      new_password = valid_usuario_password()

      {:ok, lv, _html} = live(conn, ~p"/meta_schema_usuario/settings")

      form =
        form(lv, "#password_form", %{
          "usuario" => %{
            "email" => usuario.email,
            "password" => new_password,
            "password_confirmation" => new_password
          }
        })

      render_submit(form)

      new_password_conn = follow_trigger_action(form, conn)

      assert redirected_to(new_password_conn) == ~p"/meta_schema_usuario/settings"

      assert get_session(new_password_conn, :usuario_token) != get_session(conn, :usuario_token)

      assert Phoenix.Flash.get(new_password_conn.assigns.flash, :info) =~
               "Password updated successfully"

      assert Autenticacion.get_usuario_by_email_and_password(usuario.email, new_password)
    end

    test "renders errors with invalid data (phx-change)", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/meta_schema_usuario/settings")

      result =
        lv
        |> element("#password_form")
        |> render_change(%{
          "usuario" => %{
            "password" => "too short",
            "password_confirmation" => "does not match"
          }
        })

      assert result =~ "Save Password"
      assert result =~ "should be at least 12 character(s)"
      assert result =~ "does not match password"
    end

    test "renders errors with invalid data (phx-submit)", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/meta_schema_usuario/settings")

      result =
        lv
        |> form("#password_form", %{
          "usuario" => %{
            "password" => "too short",
            "password_confirmation" => "does not match"
          }
        })
        |> render_submit()

      assert result =~ "Save Password"
      assert result =~ "should be at least 12 character(s)"
      assert result =~ "does not match password"
    end
  end

  describe "confirm email" do
    setup %{conn: conn} do
      usuario = usuario_fixture()
      email = unique_usuario_email()

      token =
        extract_usuario_token(fn url ->
          Autenticacion.deliver_usuario_update_email_instructions(%{usuario | email: email}, usuario.email, url)
        end)

      %{conn: log_in_usuario(conn, usuario), token: token, email: email, usuario: usuario}
    end

    test "updates the usuario email once", %{conn: conn, usuario: usuario, token: token, email: email} do
      {:error, redirect} = live(conn, ~p"/meta_schema_usuario/settings/confirm-email/#{token}")

      assert {:live_redirect, %{to: path, flash: flash}} = redirect
      assert path == ~p"/meta_schema_usuario/settings"
      assert %{"info" => message} = flash
      assert message == "Email changed successfully."
      refute Autenticacion.get_usuario_by_email(usuario.email)
      assert Autenticacion.get_usuario_by_email(email)

      # use confirm token again
      {:error, redirect} = live(conn, ~p"/meta_schema_usuario/settings/confirm-email/#{token}")
      assert {:live_redirect, %{to: path, flash: flash}} = redirect
      assert path == ~p"/meta_schema_usuario/settings"
      assert %{"error" => message} = flash
      assert message == "Email change link is invalid or it has expired."
    end

    test "does not update email with invalid token", %{conn: conn, usuario: usuario} do
      {:error, redirect} = live(conn, ~p"/meta_schema_usuario/settings/confirm-email/oops")
      assert {:live_redirect, %{to: path, flash: flash}} = redirect
      assert path == ~p"/meta_schema_usuario/settings"
      assert %{"error" => message} = flash
      assert message == "Email change link is invalid or it has expired."
      assert Autenticacion.get_usuario_by_email(usuario.email)
    end

    test "redirects if usuario is not logged in", %{token: token} do
      conn = build_conn()
      {:error, redirect} = live(conn, ~p"/meta_schema_usuario/settings/confirm-email/#{token}")
      assert {:redirect, %{to: path, flash: flash}} = redirect
      assert path == ~p"/meta_schema_usuario/log-in"
      assert %{"error" => message} = flash
      assert message == "You must log in to access this page."
    end
  end
end
