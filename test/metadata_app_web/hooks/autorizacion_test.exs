defmodule MetadataAppWeb.Hooks.AutorizacionTest do
  use MetadataAppWeb.ConnCase, async: true

  alias Phoenix.LiveView
  alias MetadataAppWeb.Hooks.Autorizacion
  alias MetadataApp.{Permissions, Repo}
  alias MetadataApp.Autenticacion.{Empresa, Scope}

  import MetadataApp.AutenticacionFixtures

  defp empresa_fixture do
    {:ok, empresa} =
      %Empresa{} |> Empresa.changeset(%{nombre: "Empresa #{System.unique_integer()}"}) |> Repo.insert()

    empresa
  end

  defp socket_con_scope(scope) do
    %LiveView.Socket{
      endpoint: MetadataAppWeb.Endpoint,
      assigns: %{__changed__: %{}, flash: %{}, current_scope: scope}
    }
  end

  test "sin usuario autenticado -> halt y redirige (a login)" do
    socket = socket_con_scope(nil)

    {:halt, updated} = Autorizacion.on_mount({"algo", "leer"}, %{}, %{}, socket)

    refute updated.redirected == nil
  end

  test "autenticado pero sin el permiso -> halt y redirige (a home)" do
    usuario = usuario_fixture()
    empresa = empresa_fixture()
    scope = %Scope{usuario: usuario, empresa_activa: empresa}
    socket = socket_con_scope(scope)

    {:halt, updated} = Autorizacion.on_mount({"algo", "leer"}, %{}, %{}, socket)

    refute updated.redirected == nil
  end

  test "autenticado con el permiso -> cont, no redirige" do
    usuario = usuario_fixture()
    empresa = empresa_fixture()
    {:ok, permiso} = Permissions.crear_permiso(%{recurso: "algo_hook", accion: "leer"})
    {:ok, rol} = Permissions.crear_rol(%{empresa_id: empresa.id, nombre: "Rol hook test"})
    {:ok, _} = Permissions.asignar_permiso_a_rol(rol.id, permiso.id)
    {:ok, _} = Permissions.asignar_rol(usuario.id, rol.id, empresa.id)
    scope = %Scope{usuario: usuario, empresa_activa: empresa}
    socket = socket_con_scope(scope)

    {:cont, updated} = Autorizacion.on_mount({"algo_hook", "leer"}, %{}, %{}, socket)

    assert updated.redirected == nil
  end
end
