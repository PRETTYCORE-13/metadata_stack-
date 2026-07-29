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

  defp crear_catalogo(nombre, etiqueta, nav) do
    {:ok, {header, _}} =
      MetaSchemaContext.crear_header_con_detalles(%{
        "schema_context_name" => nombre,
        "schema_context_label" => etiqueta,
        "schema_context_nav" => nav,
        "schema_visible" => true,
        "schema_context_type" => 1,
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

    html = view |> element("button", "Vista") |> render_click()

    assert html =~ "Arrastrá para cambiar el orden"
    assert html =~ "Carpeta A #{sufijo}"
    assert html =~ "Carpeta B #{sufijo}"
    assert html =~ "id=\"orden-nodo-orden_a_#{sufijo}\""
  end

  test "soltar una carpeta en nueva posición persiste el orden y se ve reflejado al reabrir la página", %{conn: conn} do
    sufijo = unique()
    nombre_a = "orden_a_#{sufijo}"
    nombre_b = "orden_b_#{sufijo}"
    crear_carpeta_raiz(nombre_a, "Carpeta A #{sufijo}")
    crear_carpeta_raiz(nombre_b, "Carpeta B #{sufijo}")

    {:ok, view, _html} = live(conn, ~p"/sysadmin/bc-list")
    view |> element("button", "Vista") |> render_click()

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

  test "reordenar DENTRO de una carpeta (subcarpeta + archivo) persiste y no toca la raíz", %{conn: conn} do
    sufijo = unique()
    padre = crear_carpeta_raiz("padre_#{sufijo}", "Padre #{sufijo}")
    sub = crear_carpeta_raiz("padre_#{sufijo}_sub", "Sub #{sufijo}")
    {:ok, sub} = MetaSchemaContext.actualizar_header(sub, %{"schema_context_nav" => "/#{padre.schema_context_name}/sub"})
    cat = crear_catalogo("cat_#{sufijo}", "Catalogo Zzz #{sufijo}", "/#{padre.schema_context_name}/zzz")

    {:ok, view, _html} = live(conn, ~p"/sysadmin/bc-list")
    html = view |> element("button", "Vista") |> render_click()

    # Cada contenedor (raíz, y cada carpeta) trae su propio data-grupo
    # único — así arrastrar dentro de "padre" nunca puede soltar sin
    # querer un ítem en la lista raíz ni en otra carpeta.
    assert html =~ "data-contenedor-id=\"#{padre.schema_context_name}\""
    assert html =~ "data-grupo=\"orden-#{padre.schema_context_name}\""

    # El catálogo ("Zzz...") quedaría último alfabéticamente frente a la
    # subcarpeta — se fuerza lo contrario arrastrándolo a la posición 0.
    render_hook(view, "mover_a", %{"id" => cat.schema_context_name, "contenedor_id" => padre.schema_context_name, "index" => 0})

    hijos =
      MetaSchemaContext.listar_headers_arbol()
      |> Enum.find(&(&1.tipo == :carpeta and &1.id == padre.schema_context_name))
      |> Map.fetch!(:hijos)
      |> Enum.map(& &1.id)

    assert hijos == [cat.schema_context_name, sub.schema_context_name]

    # La raíz (otro contenedor) no se tocó.
    raiz_sin_orden =
      MetaSchemaContext.listar_headers_arbol()
      |> Enum.filter(&(&1.tipo == :carpeta and &1.id == padre.schema_context_name))
      |> Enum.map(& &1.orden)

    assert raiz_sin_orden == [nil]
  end

  test "reordenar DENTRO de una carpeta implícita (sin '+ Nueva carpeta' propia)", %{conn: conn} do
    sufijo = unique()
    # Nadie creó la carpeta "implicita_#{sufijo}" a mano — existe solo
    # porque estos dos catálogos comparten esa ruta. Antes de este fix la
    # recursión se cortaba acá (una carpeta sin Header propio nunca
    # mostraba su contenido en "Editar vista").
    cat_a = crear_catalogo("cat_a_#{sufijo}", "Catalogo A #{sufijo}", "/implicita_#{sufijo}/a")
    cat_b = crear_catalogo("cat_b_#{sufijo}", "Catalogo B #{sufijo}", "/implicita_#{sufijo}/b")

    {:ok, view, _html} = live(conn, ~p"/sysadmin/bc-list")
    html = view |> element("button", "Vista") |> render_click()

    assert html =~ "Catalogo A #{sufijo}"
    assert html =~ "Catalogo B #{sufijo}"
    assert html =~ "carpeta automática"

    clave = "ruta:implicita_#{sufijo}"
    assert html =~ "data-contenedor-id=\"#{clave}\""

    # "B" quedaría después de "A" alfabéticamente — se fuerza lo
    # contrario arrastrándolo a la posición 0 dentro de la carpeta
    # implícita.
    render_hook(view, "mover_a", %{"id" => cat_b.schema_context_name, "contenedor_id" => clave, "index" => 0})

    hijos =
      MetaSchemaContext.listar_headers_arbol()
      |> Enum.find(&(&1.tipo == :carpeta and is_nil(&1.id) and &1.segmento == "implicita_#{sufijo}"))
      |> Map.fetch!(:hijos)
      |> Enum.map(& &1.id)

    assert hijos == [cat_b.schema_context_name, cat_a.schema_context_name]
  end

  test "cerrar 'Editar vista' con 'Listo' vuelve a la tabla normal", %{conn: conn} do
    sufijo = unique()
    crear_carpeta_raiz("orden_a_#{sufijo}", "Carpeta A #{sufijo}")

    {:ok, view, _html} = live(conn, ~p"/sysadmin/bc-list")
    view |> element("button", "Vista") |> render_click()
    html = view |> element("button", "Listo") |> render_click()

    refute html =~ "Editar vista</h2>"
    assert html =~ "Buscar por nombre o etiqueta"
  end
end
