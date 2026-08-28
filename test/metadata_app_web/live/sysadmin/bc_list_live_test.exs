defmodule MetadataAppWeb.Sysadmin.BcListLiveTest do
  use MetadataAppWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias MetadataApp.Repo
  alias MetadataApp.Autenticacion.{Empresa, Rol, UsuarioEmpresa}
  alias MetadataApp.BusinessProcessBuilder.MetaSchemaContext
  alias MetadataApp.MetaConsultas

  import MetadataApp.AutenticacionFixtures

  setup %{conn: conn} do
    usuario = usuario_fixture()

    {:ok, empresa} =
      %Empresa{} |> Empresa.changeset(%{nombre: "Empresa bc list test #{System.unique_integer()}"}) |> Repo.insert()

    {:ok, _} =
      %UsuarioEmpresa{} |> UsuarioEmpresa.changeset(%{usuario_id: usuario.id, empresa_id: empresa.id}) |> Repo.insert()

    rol_admin = Repo.get_by!(Rol, nombre: "administrador")
    {:ok, _} = MetadataApp.Permissions.asignar_rol(usuario.id, rol_admin.id, empresa.id)

    conn =
      conn
      |> log_in_usuario(usuario)
      |> Plug.Conn.put_session(:empresa_activa_id, empresa.id)

    %{conn: conn}
  end

  defp unique, do: System.unique_integer([:positive])

  defp header_vacio(nombre, detalles \\ []) do
    {:ok, {header, _}} =
      MetaSchemaContext.crear_header_con_detalles(%{
        "schema_context_name" => nombre,
        "schema_context_label" => nombre,
        "schema_context_nav" => "/#{nombre}",
        "schema_visible" => true,
        "schema_context_type" => 1,
        "detalles" => detalles
      })

    header
  end

  defp campo_referencia(nombre_campo, catalogo_destino) do
    %{
      "schema_context_field" => nombre_campo,
      "schema_context_properties" => %{
        "tipo" => "referencia",
        "catalogo" => catalogo_destino,
        "etiqueta" => nombre_campo,
        "orden" => 1,
        "visible" => true,
        "editable" => true
      }
    }
  end

  # catalogo_a: sin campos. catalogo_b: tiene un campo "referencia" hacia
  # catalogo_a (detectable en automático al agregarlo). catalogo_c: sin
  # ninguna relación con nada (fuerza el editor manual de unión).
  defp catalogos_de_prueba do
    nombre_a = "bclist_a_#{unique()}"
    nombre_b = "bclist_b_#{unique()}"
    nombre_c = "bclist_c_#{unique()}"

    header_vacio(nombre_a)
    header_vacio(nombre_b, [campo_referencia("a_id", nombre_a)])
    header_vacio(nombre_c)

    {nombre_a, nombre_b, nombre_c}
  end

  defp header_detalle_de(nombre, maestro_id) do
    {:ok, {header, _}} =
      MetaSchemaContext.crear_header_con_detalles(%{
        "schema_context_name" => nombre,
        "schema_context_label" => nombre,
        "schema_context_nav" => "/#{nombre}",
        "schema_visible" => true,
        "schema_context_type" => 1,
        "schema_encabezado_id" => maestro_id,
        "detalles" => []
      })

    header
  end

  # maestro: catálogo normal. detalle: catálogo detalle de maestro (R3,
  # encabezado_id/renglon_id) -- el aviso de fan-out (#4) y el guardrail
  # de "id" (#3) dependen de esta relación estructural, no de una
  # "referencia" configurada.
  defp catalogos_maestro_detalle_de_prueba do
    nombre_maestro = "bclist_md_maestro_#{unique()}"
    maestro = header_vacio(nombre_maestro)
    nombre_detalle = "bclist_md_detalle_#{unique()}"
    header_detalle_de(nombre_detalle, maestro.id)

    {nombre_maestro, nombre_detalle}
  end

  test "agregar tabla relacionada con relación existente se autodetecta y se persiste al crear", %{conn: conn} do
    {nombre_a, nombre_b, _nombre_c} = catalogos_de_prueba()

    {:ok, view, _html} = live(conn, ~p"/sysadmin/bc-list")

    view |> element("button", "+ Ecto") |> render_click()

    html =
      view
      |> element("form[phx-change=validar_consulta]")
      |> render_change(%{"contexto" => %{"catalogo_base" => nombre_a, "etiqueta" => "Reporte AB", "nav_final" => "reporte-ab-#{unique()}"}})

    assert html =~ "Tablas relacionadas"

    html = view |> element("button", "+ Agregar tabla relacionada") |> render_click()
    assert html =~ nombre_b

    html = view |> element("button[phx-value-catalogo=#{nombre_b}]") |> render_click()
    assert html =~ "#{nombre_b}.a_id = #{nombre_a}.id"
    assert html =~ "Cambiar"
    refute html =~ "sin unión definida"

    html =
      view
      |> element("form[phx-submit=guardar_consulta]")
      |> render_submit()

    refute html =~ "Definí la unión"

    header_creado = Enum.find(MetaSchemaContext.listar_headers(), &(&1.schema_context_label == "Reporte AB"))
    refute is_nil(header_creado)

    consulta = MetaConsultas.obtener_por_header_id(header_creado.id)
    assert MetaConsultas.catalogos_presentes(consulta) == [nombre_a, nombre_b]
    assert [join] = consulta.joins
    assert join["catalogo_destino"] == nombre_a
    assert join["campo_en_nuevo"] == "a_id"
  end

  test "agregar tabla sin relación pide definir la unión a mano antes de poder crear", %{conn: conn} do
    {nombre_a, _nombre_b, nombre_c} = catalogos_de_prueba()

    {:ok, view, _html} = live(conn, ~p"/sysadmin/bc-list")
    view |> element("button", "+ Ecto") |> render_click()

    view
    |> element("form[phx-change=validar_consulta]")
    |> render_change(%{"contexto" => %{"catalogo_base" => nombre_a, "etiqueta" => "Reporte AC", "nav_final" => "reporte-ac-#{unique()}"}})

    view |> element("button", "+ Agregar tabla relacionada") |> render_click()
    html = view |> element("button[phx-value-catalogo=#{nombre_c}]") |> render_click()
    assert html =~ "sin unión definida"

    # Intentar crear sin definir la unión: bloqueado con un error, nada se crea.
    html = view |> element("form[phx-submit=guardar_consulta]") |> render_submit()
    assert html =~ "Definí la unión"
    assert MetaSchemaContext.obtener_header_por_nombre("consulta_reporte_ac") == nil

    # Definir la unión a mano.
    html = view |> element("button", "Definir") |> render_click()
    assert html =~ "Unión con"

    view
    |> form("form[phx-submit=guardar_union_manual]", %{"campo_en_nuevo" => "id", "destino" => "#{nombre_a}:id"})
    |> render_submit()

    html = render(view)
    assert html =~ "Cambiar"
    refute html =~ "sin unión definida"

    html = view |> element("form[phx-submit=guardar_consulta]") |> render_submit()
    refute html =~ "Definí la unión"

    header_creado = Enum.find(MetaSchemaContext.listar_headers(), &(&1.schema_context_label == "Reporte AC"))
    refute is_nil(header_creado)

    consulta = MetaConsultas.obtener_por_header_id(header_creado.id)
    assert MetaConsultas.catalogos_presentes(consulta) == [nombre_a, nombre_c]
  end

  test "quitar la última tabla relacionada la saca de la lista", %{conn: conn} do
    {nombre_a, nombre_b, _nombre_c} = catalogos_de_prueba()

    {:ok, view, _html} = live(conn, ~p"/sysadmin/bc-list")
    view |> element("button", "+ Ecto") |> render_click()

    view
    |> element("form[phx-change=validar_consulta]")
    |> render_change(%{"contexto" => %{"catalogo_base" => nombre_a}})

    view |> element("button", "+ Agregar tabla relacionada") |> render_click()
    html = view |> element("button[phx-value-catalogo=#{nombre_b}]") |> render_click()
    assert html =~ nombre_b

    html = view |> element("button", "Quitar") |> render_click()
    # Esta frase solo se renderiza cuando @tablas_relacionadas volvió a
    # [] — no se puede refutar `html =~ nombre_b` a secas porque ese
    # catálogo también existe como fila real en el árbol de BC List, en
    # otra parte de la misma página.
    assert html =~ "por ahora — agregá más tablas"
  end

  # Maestro-detalle (R3) -- ver detectar_union_maestro_detalle/2 y
  # maestro_de_detalle/1 en MetaConsultas. Bug real 2026-08-26 que motiva
  # esto: agregar una tabla detalle unió "id"="id" a mano, sin ningún
  # aviso, trayendo 1 fila por maestro en vez del fan-out real.
  describe "maestro-detalle: unión autodetectada + avisos" do
    test "agregar la tabla detalle autodetecta encabezado_id -> id y avisa el fan-out", %{conn: conn} do
      {nombre_maestro, nombre_detalle} = catalogos_maestro_detalle_de_prueba()

      {:ok, view, _html} = live(conn, ~p"/sysadmin/bc-list")
      view |> element("button", "+ Ecto") |> render_click()

      view
      |> element("form[phx-change=validar_consulta]")
      |> render_change(%{"contexto" => %{"catalogo_base" => nombre_maestro}})

      view |> element("button", "+ Agregar tabla relacionada") |> render_click()
      html = view |> element("button[phx-value-catalogo=#{nombre_detalle}]") |> render_click()

      assert html =~ "#{nombre_detalle}.encabezado_id = #{nombre_maestro}.id"
      refute html =~ "sin unión definida"
      assert html =~ "Detalle de"
      assert html =~ "puede traer varias filas por cada #{nombre_maestro}"
    end

    test "el editor manual de unión avisa fan-out y guardrail cuando la tabla es detalle", %{conn: conn} do
      {nombre_maestro, nombre_detalle} = catalogos_maestro_detalle_de_prueba()

      {:ok, view, _html} = live(conn, ~p"/sysadmin/bc-list")
      view |> element("button", "+ Ecto") |> render_click()

      view
      |> element("form[phx-change=validar_consulta]")
      |> render_change(%{"contexto" => %{"catalogo_base" => nombre_maestro}})

      view |> element("button", "+ Agregar tabla relacionada") |> render_click()
      view |> element("button[phx-value-catalogo=#{nombre_detalle}]") |> render_click()

      html = view |> element("button[phx-click=abrir_union_manual]", "Cambiar") |> render_click()
      assert html =~ "Unión con"
      assert html =~ "es detalle de"
      # "id" queda preseleccionado (primera opción) al abrir -- el
      # guardrail tiene que avisar YA, sin esperar a que el admin toque nada.
      assert html =~ "casi seguro no es correcto acá"

      html =
        view
        |> element("select[name=campo_en_nuevo]")
        |> render_change(%{"campo_en_nuevo" => "encabezado_id"})

      refute html =~ "casi seguro no es correcto acá"
    end
  end
end
