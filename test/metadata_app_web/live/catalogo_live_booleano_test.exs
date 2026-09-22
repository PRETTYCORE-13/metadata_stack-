defmodule MetadataAppWeb.CatalogoLiveBooleanoTest do
  @moduledoc """
  SPEC-SYS-1109202606 R19 -- una columna de negocio tipo "boolean" se
  pinta en la tabla del usuario final como un checkbox deshabilitado
  (marcado/desmarcado), nunca como el texto "true"/"false".
  """
  use MetadataAppWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import MetadataApp.AutenticacionFixtures

  alias MetadataApp.Repo
  alias MetadataApp.Autenticacion.{Empresa, Rol, UsuarioEmpresa}
  alias MetadataApp.MetaBusinessProcess.Catalogos.MetaFixtureCliente
  alias MetadataApp.Permissions

  setup %{conn: conn} do
    usuario = usuario_fixture()

    {:ok, empresa} =
      %Empresa{} |> Empresa.changeset(%{nombre: "Empresa booleano test #{System.unique_integer()}"}) |> Repo.insert()

    {:ok, _} =
      %UsuarioEmpresa{} |> UsuarioEmpresa.changeset(%{usuario_id: usuario.id, empresa_id: empresa.id}) |> Repo.insert()

    rol_admin = Repo.get_by!(Rol, nombre: "administrador")
    {:ok, _} = Permissions.asignar_rol(usuario.id, rol_admin.id, empresa.id)
    {:ok, _} = Permissions.crear_permiso(%{recurso: "meta_fixture_cliente", accion: "leer"})

    conn =
      conn
      |> log_in_usuario(usuario)
      |> Plug.Conn.put_session(:empresa_activa_id, empresa.id)

    %{conn: conn}
  end

  defp guid, do: Ecto.UUID.generate() |> String.replace("-", "")

  defp fixture_cliente(attrs) do
    %MetaFixtureCliente{}
    |> MetaFixtureCliente.changeset(attrs)
    |> Ecto.Changeset.put_change(:insert_guid, guid())
    |> Repo.insert!()
  end

  defp celda_activo(view) do
    view |> element("tbody td[data-col='meta_fixture_cliente_activo']") |> render()
  end

  # meta_fixture_cliente tiene cargar_todos_por_default: false (carga
  # diferida, ver datos_solicitados?/1) -- sin esto la tabla no trae
  # ninguna fila, ver catalogo_live_filtros_test.exs para el mismo
  # criterio ya establecido.
  defp buscar(view, texto), do: render_change(view, "buscar_general", %{"value" => texto})

  test "true se pinta con checkbox marcado, nunca el texto \"true\"", %{conn: conn} do
    sufijo = System.unique_integer([:positive])

    fixture_cliente(%{
      meta_fixture_cliente_nombre: "Con activo #{sufijo}",
      meta_fixture_cliente_edad: 30,
      meta_fixture_cliente_venta: Decimal.new("1"),
      meta_fixture_cliente_activo: true
    })

    {:ok, view, _html} = live(conn, "/__test__/fixture-cliente")
    buscar(view, "Con activo #{sufijo}")

    celda = celda_activo(view)
    assert celda =~ ~s(type="checkbox")
    assert celda =~ "checked"
    refute celda =~ ">true<"
    refute celda =~ ">false<"
  end

  test "false se pinta con checkbox desmarcado, nunca el texto \"false\"", %{conn: conn} do
    sufijo = System.unique_integer([:positive])

    fixture_cliente(%{
      meta_fixture_cliente_nombre: "Sin activo #{sufijo}",
      meta_fixture_cliente_edad: 30,
      meta_fixture_cliente_venta: Decimal.new("1"),
      meta_fixture_cliente_activo: false
    })

    {:ok, view, _html} = live(conn, "/__test__/fixture-cliente")
    buscar(view, "Sin activo #{sufijo}")

    celda = celda_activo(view)
    assert celda =~ ~s(type="checkbox")
    refute celda =~ "checked"
    refute celda =~ ">true<"
    refute celda =~ ">false<"
  end

  test "el checkbox está deshabilitado -- es solo lectura, no un formulario", %{conn: conn} do
    sufijo = System.unique_integer([:positive])

    fixture_cliente(%{
      meta_fixture_cliente_nombre: "Deshabilitado #{sufijo}",
      meta_fixture_cliente_edad: 30,
      meta_fixture_cliente_venta: Decimal.new("1"),
      meta_fixture_cliente_activo: true
    })

    {:ok, view, _html} = live(conn, "/__test__/fixture-cliente")
    buscar(view, "Deshabilitado #{sufijo}")

    assert celda_activo(view) =~ "disabled"
  end
end
