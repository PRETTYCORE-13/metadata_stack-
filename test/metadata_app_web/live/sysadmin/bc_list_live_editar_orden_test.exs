defmodule MetadataAppWeb.Sysadmin.BcListLiveEditarOrdenTest do
  use MetadataAppWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias MetadataApp.Repo
  alias MetadataApp.Autenticacion.{Empresa, Rol, UsuarioEmpresa}
  alias MetadataApp.BusinessProcessBuilder.MetaSchemaContext

  import MetadataApp.AutenticacionFixtures

  setup %{conn: conn} do
    usuario = usuario_fixture()

    {:ok, empresa} =
      %Empresa{} |> Empresa.changeset(%{nombre: "Empresa editar orden test #{System.unique_integer()}"}) |> Repo.insert()

    {:ok, _} =
      %UsuarioEmpresa{} |> UsuarioEmpresa.changeset(%{usuario_id: usuario.id, empresa_id: empresa.id}) |> Repo.insert()

    rol_admin = Repo.get_by!(Rol, nombre: "administrador")
    {:ok, _} = MetadataApp.Permissions.asignar_rol(usuario.id, rol_admin.id, empresa.id)

    conn = conn |> log_in_usuario(usuario) |> Plug.Conn.put_session(:empresa_activa_id, empresa.id)
    %{conn: conn}
  end

  defp unique, do: System.unique_integer([:positive])

  defp crear_carpeta_raiz(nombre, etiqueta) do
    {:ok, {header, _}} =
      MetaSchemaContext.crear_header_con_detalles(%{
        "schema_context_name" => nombre,
        "schema_context_label" => etiqueta,
        "schema_context_nav" => "/#{nombre}",
        "schema_visible" => true,
        "schema_context_type" => 2,
        "detalles" => []
      })

    header
  end

  test "botón 'Editar vista' abre el panel arrastrable con las carpetas raíz", %{conn: conn} do
    sufijo = unique()
    crear_carpeta_raiz("orden_a_#{sufijo}", "Carpeta A #{sufijo}")
    crear_carpeta_raiz("orden_b_#{sufijo}", "Carpeta B #{sufijo}")

    {:ok, view, html} = live(conn, ~p"/sysadmin/bc-list")
    refute html =~ "Editar vista</h2>"

    html = view |> element("button", "Editar vista") |> render_click()

    assert html =~ "Arrastrá las carpetas"
    assert html =~ "Carpeta A #{sufijo}"
    assert html =~ "Carpeta B #{sufijo}"
    assert html =~ "id=\"orden-carpeta-orden_a_#{sufijo}\""
  end

  test "soltar una carpeta en nueva posición persiste el orden y se ve reflejado al reabrir la página", %{conn: conn} do
    sufijo = unique()
    nombre_a = "orden_a_#{sufijo}"
    nombre_b = "orden_b_#{sufijo}"
    crear_carpeta_raiz(nombre_a, "Carpeta A #{sufijo}")
    crear_carpeta_raiz(nombre_b, "Carpeta B #{sufijo}")

    {:ok, view, _html} = live(conn, ~p"/sysadmin/bc-list")
    view |> element("button", "Editar vista") |> render_click()

    # Simula lo que manda el hook ListaOrdenable al soltar (Sortable.js
    # onEnd) — arrastrar "B" a la posición 0, adelante de "A".
    render_hook(view, "mover_a", %{"id" => nombre_b, "contenedor_id" => "", "index" => 0})

    consulta_directa =
      MetaSchemaContext.listar_headers_arbol()
      |> Enum.filter(&(&1.tipo == :carpeta and &1.id in [nombre_a, nombre_b]))
      |> Enum.map(& &1.id)

    assert consulta_directa == [nombre_b, nombre_a]

    # Reabrir la página (nuevo mount, como si el navegador se hubiera
    # reiniciado) confirma que quedó persistido, no solo en el socket.
    {:ok, _view2, html2} = live(conn, ~p"/sysadmin/bc-list")
    pos_a = :binary.match(html2, "Carpeta A #{sufijo}") |> elem(0)
    pos_b = :binary.match(html2, "Carpeta B #{sufijo}") |> elem(0)
    assert pos_b < pos_a
  end

  test "cerrar 'Editar vista' con 'Listo' vuelve a la tabla normal", %{conn: conn} do
    sufijo = unique()
    crear_carpeta_raiz("orden_a_#{sufijo}", "Carpeta A #{sufijo}")

    {:ok, view, _html} = live(conn, ~p"/sysadmin/bc-list")
    view |> element("button", "Editar vista") |> render_click()
    html = view |> element("button", "Listo") |> render_click()

    refute html =~ "Editar vista</h2>"
    assert html =~ "Buscar por nombre o etiqueta"
  end
end
