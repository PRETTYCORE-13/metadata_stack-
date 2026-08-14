defmodule MetadataAppWeb.UsuarioLive.PrimerArranqueTest do
  use MetadataAppWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import MetadataApp.AutenticacionFixtures

  alias MetadataApp.Autenticacion
  alias MetadataApp.Repo

  describe "wizard de primer arranque" do
    test "renderiza el formulario cuando no existe ningún sysadmin", %{conn: conn} do
      refute Autenticacion.existe_sysadmin?()

      {:ok, _lv, html} = live(conn, ~p"/primer-arranque")

      assert html =~ "Configurá tu sistema"
      assert html =~ "Nombre de la empresa"
    end

    test "crea sysadmin + empresa y loguea con el POST real (phx-trigger-action)", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/primer-arranque")

      form =
        form(lv, "#primer_arranque_form",
          usuario: %{
            nombre_empresa: "Empresa de Prueba",
            email: "admin@ejemplo.com",
            password: "una_contrasena_larga_123",
            password_confirmation: "una_contrasena_larga_123"
          }
        )

      assert render_submit(form) =~ "phx-trigger-action"

      conn = follow_trigger_action(form, conn)

      assert Autenticacion.existe_sysadmin?()

      usuario = Autenticacion.get_usuario_by_email("admin@ejemplo.com")
      assert usuario.super_admin

      assert Repo.get_by(MetadataApp.Autenticacion.Empresa, nombre: "Empresa de Prueba")

      # phx-trigger-action dispara un POST real contra el login por
      # contraseña ya existente -- confirma que la sesión se estableció
      # de verdad, no solo que la creación funcionó.
      assert get_session(conn, :usuario_token)
    end

    test "no deja crear un segundo sysadmin si ya existe uno", %{conn: conn} do
      _sysadmin = usuario_fixture() |> Ecto.Changeset.change(%{super_admin: true}) |> Repo.update!()

      assert {:error, {:live_redirect, %{to: "/meta_schema_usuario/log-in"}}} =
               live(conn, ~p"/primer-arranque")
    end

    test "muestra error si las contraseñas no coinciden", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/primer-arranque")

      html =
        form(lv, "#primer_arranque_form",
          usuario: %{
            nombre_empresa: "Empresa de Prueba",
            email: "admin@ejemplo.com",
            password: "una_contrasena_larga_123",
            password_confirmation: "otra_distinta"
          }
        )
        |> render_submit()

      assert html =~ "no coinciden"
      refute Autenticacion.existe_sysadmin?()
    end
  end
end
