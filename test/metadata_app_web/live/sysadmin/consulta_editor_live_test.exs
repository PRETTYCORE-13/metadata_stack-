defmodule MetadataAppWeb.Sysadmin.ConsultaEditorLiveTest do
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
      %Empresa{} |> Empresa.changeset(%{nombre: "Empresa editor consulta #{System.unique_integer()}"}) |> Repo.insert()

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

  defp criar_consulta do
    nombre = "consulta_editor_test_#{unique()}"

    {:ok, {header, _}} =
      MetaSchemaContext.crear_header_con_detalles(%{
        "schema_context_name" => nombre,
        "schema_context_label" => "Consulta editor test",
        "schema_context_nav" => "/#{nombre}",
        "schema_visible" => true,
        "schema_context_type" => 3,
        "detalles" => []
      })

    {:ok, consulta} = MetaConsultas.crear(header, "meta_fixture_cliente")
    {header, consulta}
  end

  # Etiqueta (tab "Configuración") y visibilidad/totalizar (tab "Get
  # Config" → Columnas) viven en dos forms/eventos separados desde el
  # rediseño en tabs (2026-08-25) -- antes era un solo form/evento
  # "guardar_campos" que hacía las tres cosas juntas.
  test "cambia etiqueta (Configuración) y visibilidad/agregacion_activa (Get Config) de un campo", %{conn: conn} do
    {header, _consulta} = criar_consulta()

    {:ok, view, html} = live(conn, ~p"/sysadmin/bc-list/#{header.schema_context_name}/consulta")
    assert html =~ "Consulta editor test"

    render_click(view, "cambiar_tab", %{"tab" => "get_config"})
    assert render(view) =~ "meta_fixture_cliente_edad"

    html_columnas =
      view
      |> form("form[phx-submit=guardar_columnas]", %{"visibles" => ["meta_fixture_cliente::meta_fixture_cliente_nombre"]})
      |> render_submit()

    assert html_columnas =~ "Columnas actualizadas."

    # Totales (SPEC-SYS-0209202601) -- ya no es un checkbox del form de
    # arriba, es un toggle inmediato (celda_totales/1).
    render_click(view, "cambiar_agregacion_activa", %{"campo" => "meta_fixture_cliente::meta_fixture_cliente_edad", "activo" => "true"})

    render_click(view, "cambiar_tab", %{"tab" => "configuracion"})

    html_guardado =
      view
      |> form("form[phx-submit=guardar_etiquetas]", %{
        "etiquetas" => %{"meta_fixture_cliente::meta_fixture_cliente_edad" => "Edad del cliente"}
      })
      |> render_submit()

    assert html_guardado =~ "Edad del cliente"

    consulta_actualizada = MetaConsultas.obtener_por_header_id(header.id)
    campo_edad = Enum.find(consulta_actualizada.campos, &(&1["campo"] == "meta_fixture_cliente_edad"))
    campo_nombre = Enum.find(consulta_actualizada.campos, &(&1["campo"] == "meta_fixture_cliente_nombre"))
    campo_venta = Enum.find(consulta_actualizada.campos, &(&1["campo"] == "meta_fixture_cliente_venta"))

    assert campo_edad["etiqueta"] == "Edad del cliente"
    assert campo_edad["agregacion_activa"] == true
    assert campo_nombre["visible"] == true
    assert campo_venta["visible"] == false
  end

  # Bug real 2026-08-27 ("no puedo configurar rango de fechas con
  # Acotado"): el botón de Parámetro no chequeaba "visible", así que se
  # podía prender Parámetro en una columna todavía no visible -- quedaba
  # es_parametro:true + visible:false persistido, celdas_parametro/1
  # nunca renderiza eso como interactivo (exige visible:true), así que
  # "Acotado" no aparecía nunca aunque Parámetro ya dijera "Sí".
  test "el botón de Parámetro viene disabled en una columna no visible, y el toggle server-side lo respeta", %{conn: conn} do
    {header, _consulta} = criar_consulta()

    {:ok, view, _html} = live(conn, ~p"/sysadmin/bc-list/#{header.schema_context_name}/consulta")
    render_click(view, "cambiar_tab", %{"tab" => "get_config"})

    id = "meta_fixture_cliente::meta_fixture_cliente_nombre"

    # Ninguna columna visible -- estado inicial de "no visible" sin pasar
    # por ningún otro handler.
    html = view |> form("form[phx-submit=guardar_columnas]", %{"visibles" => []}) |> render_submit()
    assert html =~ ~s(phx-value-campo="#{id}")

    # El botón de Parámetro para esa fila viene disabled.
    assert view
           |> element("button[phx-click=cambiar_es_parametro][phx-value-campo=\"#{id}\"]")
           |> render() =~ "disabled"

    # Aunque se dispare el evento igual (bypass del disabled, ej. DOM
    # viejo) -- el handler lo ignora, sigue sin ser parámetro.
    render_click(view, "cambiar_es_parametro", %{"campo" => id})
    consulta = MetaConsultas.obtener_por_header_id(header.id)
    assert Enum.find(consulta.campos, &(&1["campo"] == "meta_fixture_cliente_nombre"))["es_parametro"] != true

    # Visible primero -- ahora sí se puede prender Parámetro.
    view |> form("form[phx-submit=guardar_columnas]", %{"visibles" => [id]}) |> render_submit()
    refute view |> element("button[phx-click=cambiar_es_parametro][phx-value-campo=\"#{id}\"]") |> render() =~ "disabled"

    render_click(view, "cambiar_es_parametro", %{"campo" => id})
    consulta = MetaConsultas.obtener_por_header_id(header.id)
    assert Enum.find(consulta.campos, &(&1["campo"] == "meta_fixture_cliente_nombre"))["es_parametro"] == true
  end

  # Mismo chequeo que el test de arriba, pero para los otros 3 tipos
  # reales del catálogo fixture (referencia/integer/decimal) -- confirma
  # que el gate de toggle_es_parametro/1 es parejo entre tipos, no algo
  # que solo se probó para "string" (pedido explícito: probar los demás
  # tipos de datos).
  for {campo, _tipo} <- [{"meta_fixture_cliente_sucursal_id", "referencia"}, {"meta_fixture_cliente_edad", "integer"}, {"meta_fixture_cliente_venta", "decimal"}] do
    test "el botón de Parámetro viene disabled sin visible -- #{campo}", %{conn: conn} do
      {header, _consulta} = criar_consulta()
      {:ok, view, _html} = live(conn, ~p"/sysadmin/bc-list/#{header.schema_context_name}/consulta")
      render_click(view, "cambiar_tab", %{"tab" => "get_config"})

      id = "meta_fixture_cliente::#{unquote(campo)}"

      view |> form("form[phx-submit=guardar_columnas]", %{"visibles" => []}) |> render_submit()

      assert view
             |> element("button[phx-click=cambiar_es_parametro][phx-value-campo=\"#{id}\"]")
             |> render() =~ "disabled"

      render_click(view, "cambiar_es_parametro", %{"campo" => id})
      consulta = MetaConsultas.obtener_por_header_id(header.id)
      assert Enum.find(consulta.campos, &(&1["campo"] == unquote(campo)))["es_parametro"] != true

      view |> form("form[phx-submit=guardar_columnas]", %{"visibles" => [id]}) |> render_submit()
      refute view |> element("button[phx-click=cambiar_es_parametro][phx-value-campo=\"#{id}\"]") |> render() =~ "disabled"

      render_click(view, "cambiar_es_parametro", %{"campo" => id})
      consulta = MetaConsultas.obtener_por_header_id(header.id)
      assert Enum.find(consulta.campos, &(&1["campo"] == unquote(campo)))["es_parametro"] == true
    end
  end

  # Round-trip: configurar Acotado/Tipo/Origen a fondo, apagar Visible
  # (Get Config lo permite -- no fuerza "apagar Parámetro" al mismo
  # tiempo), prenderlo de nuevo -- nada debería perderse ni quedar en un
  # estado no interactivo. Cubre los 3 grupos reales de celdas_parametro/1
  # (date, string/referencia, integer/decimal) con datos reales del
  # catálogo fixture + un campo "date" sintético (el fixture no trae uno
  # nativo).
  test "Acotado/Tipo/Origen sobreviven un apagado y reencendido de Visible, en cada grupo de tipo", %{conn: conn} do
    {header, consulta} = criar_consulta()

    campo_fecha = %{
      "catalogo" => consulta.catalogo_base,
      "campo" => "fecha_registro",
      "etiqueta" => "Fecha",
      "tipo" => "date",
      "orden" => 99,
      "visible" => true,
      "agregacion_activa" => false,
      "es_parametro" => false
    }

    campos = Enum.reject(consulta.campos, &(&1["campo"] == "fecha_registro")) ++ [campo_fecha]
    {:ok, _} = MetaConsultas.actualizar_campos(consulta, campos)

    {:ok, view, _html} = live(conn, ~p"/sysadmin/bc-list/#{header.schema_context_name}/consulta")
    render_click(view, "cambiar_tab", %{"tab" => "get_config"})

    id_fecha = "meta_fixture_cliente::fecha_registro"
    id_edad = "meta_fixture_cliente::meta_fixture_cliente_edad"
    id_nombre = "meta_fixture_cliente::meta_fixture_cliente_nombre"
    id_sucursal = "meta_fixture_cliente::meta_fixture_cliente_sucursal_id"

    # Visible ya viene true por default (campos_del_catalogo/2) -- prende
    # Parámetro + Acotado (date/integer) y un tipo_filtro no-default
    # (string) en los 4.
    for id <- [id_fecha, id_edad, id_nombre, id_sucursal], do: render_click(view, "cambiar_es_parametro", %{"campo" => id})
    for id <- [id_fecha, id_edad], do: render_click(view, "cambiar_acotado", %{"campo" => id})
    render_change(view, "cambiar_tipo_filtro", %{"tipo_filtro" => %{id_nombre => "igual"}})

    # Apaga Visible de los 4 juntos, sin tocar nada de Parámetro/Acotado.
    view |> form("form[phx-submit=guardar_columnas]", %{"visibles" => []}) |> render_submit()

    consulta_oculta = MetaConsultas.obtener_por_header_id(header.id)
    for campo <- ~w(fecha_registro meta_fixture_cliente_edad meta_fixture_cliente_nombre meta_fixture_cliente_sucursal_id) do
      c = Enum.find(consulta_oculta.campos, &(&1["campo"] == campo))
      assert c["visible"] == false
      assert c["es_parametro"] == true, "es_parametro debería seguir true (oculto, no perdido) para #{campo}"
    end

    # Prende Visible de nuevo -- Acotado/Tipo tienen que seguir ahí y ser
    # interactivos, no reseteados a default ni escondidos.
    html = view |> form("form[phx-submit=guardar_columnas]", %{"visibles" => [id_fecha, id_edad, id_nombre, id_sucursal]}) |> render_submit()

    consulta_final = MetaConsultas.obtener_por_header_id(header.id)
    assert Enum.find(consulta_final.campos, &(&1["campo"] == "fecha_registro"))["acotado"] == true
    assert Enum.find(consulta_final.campos, &(&1["campo"] == "meta_fixture_cliente_edad"))["acotado"] == true
    assert Enum.find(consulta_final.campos, &(&1["campo"] == "meta_fixture_cliente_nombre"))["tipo_filtro"] == "igual"

    assert html =~ "Acot."
    # Cada botón de Parámetro de los 4 vuelve a estar habilitado (no
    # "disabled" en su <button>).
    for id <- [id_fecha, id_edad, id_nombre, id_sucursal] do
      refute view |> element("button[phx-click=cambiar_es_parametro][phx-value-campo=\"#{id}\"]") |> render() =~ "disabled"
    end
  end

  test "celda_totales no ofrece el toggle para un campo no numérico (string)", %{conn: conn} do
    {header, _consulta} = criar_consulta()

    {:ok, view, _html} = live(conn, ~p"/sysadmin/bc-list/#{header.schema_context_name}/consulta")
    html = render_click(view, "cambiar_tab", %{"tab" => "get_config"})

    refute html =~ ~s(phx-click="cambiar_agregacion_activa" phx-value-campo="meta_fixture_cliente::meta_fixture_cliente_nombre")
  end

  # Defensa en profundidad: aunque celda_totales/1 no pinte el toggle
  # para un campo no numérico, un cliente manipulado podría mandar el
  # evento igual (render_click no pasa por la validación de LiveViewTest
  # contra el DOM) -- confirma que el handler lo descarta server-side.
  test "cambiar_agregacion_activa ignora un campo no numérico aunque llegue el evento", %{conn: conn} do
    {header, _consulta} = criar_consulta()

    {:ok, view, _html} = live(conn, ~p"/sysadmin/bc-list/#{header.schema_context_name}/consulta")

    render_click(view, "cambiar_agregacion_activa", %{"campo" => "meta_fixture_cliente::meta_fixture_cliente_nombre", "activo" => "true"})

    consulta_actualizada = MetaConsultas.obtener_por_header_id(header.id)
    campo_nombre = Enum.find(consulta_actualizada.campos, &(&1["campo"] == "meta_fixture_cliente_nombre"))

    assert campo_nombre["agregacion_activa"] != true
  end

  # Drag-and-drop (hook ListaOrdenable, mismo componente que BcMotorLive
  # usa en su Get View) reemplazó los botones ▲/▼ (2026-08-26) -- el
  # hook empuja "mover_a" con el id del <tr> soltado y el índice nuevo,
  # mismo evento/shape que ya usa BcMotorLive para su propia Get View.
  test "mover_a (drag-and-drop) reordena las columnas del Get", %{conn: conn} do
    {header, consulta} = criar_consulta()
    assert Enum.map(Enum.sort_by(consulta.campos, & &1["orden"]), & &1["campo"]) |> Enum.take(3) ==
             ~w(meta_fixture_cliente_nombre meta_fixture_cliente_edad meta_fixture_cliente_venta)

    {:ok, view, _html} = live(conn, ~p"/sysadmin/bc-list/#{header.schema_context_name}/consulta")

    render_click(view, "mover_a", %{"id" => "meta_fixture_cliente::meta_fixture_cliente_venta", "index" => 0})

    consulta_actualizada = MetaConsultas.obtener_por_header_id(header.id)
    orden = consulta_actualizada.campos |> Enum.sort_by(& &1["orden"]) |> Enum.map(& &1["campo"])
    assert Enum.at(orden, 0) == "meta_fixture_cliente_venta"
  end

  # "Es acotado"/"Defaults" (rediseño 2026-08-27) reemplazó el <select>
  # único "Parámetro" -- el admin sigue teniendo que prender "Parámetro"
  # (columna nueva, "es_parametro") a propósito por columna, ninguna es
  # automática; una vez prendida, "Es acotado" (click, guardado
  # inmediato) decide si el default es un rango o un solo valor. Una
  # Consulta puede tener VARIAS columnas Fecha, cada una con su propio
  # acotado/modo -- acá se prueban dos a la vez para blindar esa
  # independencia (mismo caso real que motivó el rediseño: dos
  # "fecha_registro" de dos catálogos distintos).
  test "acota dos columnas Fecha, cada una con su propio modo, y las aplica de forma independiente", %{conn: conn} do
    {header, consulta} = criar_consulta()

    campo_fecha_1 = %{
      "catalogo" => consulta.catalogo_base,
      "campo" => "fecha_alta",
      "etiqueta" => "Fecha de alta",
      "tipo" => "date",
      "orden" => 99,
      "visible" => true,
      "agregacion_activa" => false,
      "es_parametro" => true
    }

    campo_fecha_2 = %{
      "catalogo" => consulta.catalogo_base,
      "campo" => "fecha_baja",
      "etiqueta" => "Fecha de baja",
      "tipo" => "date",
      "orden" => 100,
      "visible" => true,
      "agregacion_activa" => false,
      "es_parametro" => true
    }

    {:ok, consulta} = MetaConsultas.actualizar_campos(consulta, consulta.campos ++ [campo_fecha_1, campo_fecha_2])

    {:ok, view, _html} = live(conn, ~p"/sysadmin/bc-list/#{header.schema_context_name}/consulta")
    html = render_click(view, "cambiar_tab", %{"tab" => "get_config"})
    assert html =~ "Acot."
    assert html =~ "Default"

    id_1 = "#{consulta.catalogo_base}::fecha_alta"
    id_2 = "#{consulta.catalogo_base}::fecha_baja"

    # Botones (phx-click) -- a diferencia de un <select>/<input> con
    # phx-change, acá phx-value-campo/modo SÍ llega bien en dispatch
    # crudo: el cliente JS de LiveView lee phx-value-* del elemento
    # clickeado en eventos de click (ver comentario grande sobre
    # "cambiar_acotado" en el LiveView).
    render_click(view, "cambiar_acotado", %{"campo" => id_1})
    render_click(view, "cambiar_defaults_modo", %{"campo" => id_1, "modo" => "anio_actual"})
    render_click(view, "cambiar_defaults_modo", %{"campo" => id_2, "modo" => "actual"})

    consulta_actualizada = MetaConsultas.obtener_por_header_id(header.id)
    campo_1 = Enum.find(consulta_actualizada.campos, &(&1["campo"] == "fecha_alta"))
    campo_2 = Enum.find(consulta_actualizada.campos, &(&1["campo"] == "fecha_baja"))

    assert campo_1["acotado"] == true
    assert campo_1["defaults"]["modo"] == "anio_actual"
    assert campo_2["acotado"] in [false, nil]
    assert campo_2["defaults"]["modo"] == "actual"
  end

  # Mismo bug/motivo que el test de arriba, para el <input type="text">
  # de fórmula (modo "formula") -- el name real es
  # defaults_valor[<id>]/defaults_valor_hasta[<id>], con
  # form="form-guardar-columnas" (obligatorio: sin ancestro <form> ni
  # atributo form="", LiveView revienta al primer change).
  test "el rango de fecha (modo fórmula) guarda desde/hasta a través del <input> real del DOM", %{conn: conn} do
    {header, consulta} = criar_consulta()

    campo_fecha = %{
      "catalogo" => consulta.catalogo_base,
      "campo" => "fecha_alta",
      "etiqueta" => "Fecha de alta",
      "tipo" => "date",
      "orden" => 99,
      "visible" => true,
      "agregacion_activa" => false,
      "es_parametro" => true,
      "acotado" => true,
      "defaults" => %{"modo" => "formula"}
    }

    {:ok, consulta} = MetaConsultas.actualizar_campos(consulta, consulta.campos ++ [campo_fecha])
    id = "#{consulta.catalogo_base}::fecha_alta"

    {:ok, view, _html} = live(conn, ~p"/sysadmin/bc-list/#{header.schema_context_name}/consulta")
    render_click(view, "cambiar_tab", %{"tab" => "get_config"})

    view
    |> element("input[name=\"defaults_valor[#{id}]\"]")
    |> render_change(%{"defaults_valor" => %{id => "primer_dia_anio"}})

    view
    |> element("input[name=\"defaults_valor_hasta[#{id}]\"]")
    |> render_change(%{"defaults_valor_hasta" => %{id => "actual"}})

    consulta_actualizada = MetaConsultas.obtener_por_header_id(header.id)
    campo_persistido = Enum.find(consulta_actualizada.campos, &(&1["campo"] == "fecha_alta"))
    assert campo_persistido["defaults"]["valor"] == "primer_dia_anio"
    assert campo_persistido["defaults"]["valor_hasta"] == "actual"
  end

  # <select> compacto (2026-08-27, a pedido explícito -- reemplaza la
  # fila de botones "Tipo", se amontonaba/enrollaba con 3-4 opciones en
  # una columna angosta) para elegir tipo_filtro de un campo string.
  test "el <select> de Tipo (tipo_filtro) guarda a través del DOM real", %{conn: conn} do
    {header, consulta} = criar_consulta()

    campos =
      Enum.map(consulta.campos, fn c ->
        if c["campo"] == "meta_fixture_cliente_nombre", do: Map.put(c, "es_parametro", true), else: c
      end)

    {:ok, consulta} = MetaConsultas.actualizar_campos(consulta, campos)
    id = "#{consulta.catalogo_base}::meta_fixture_cliente_nombre"

    {:ok, view, _html} = live(conn, ~p"/sysadmin/bc-list/#{header.schema_context_name}/consulta")
    render_click(view, "cambiar_tab", %{"tab" => "get_config"})

    view
    |> element("select[name=\"tipo_filtro[#{id}]\"]")
    |> render_change(%{"tipo_filtro" => %{id => "igual"}})

    consulta_actualizada = MetaConsultas.obtener_por_header_id(header.id)
    campo_persistido = Enum.find(consulta_actualizada.campos, &(&1["campo"] == "meta_fixture_cliente_nombre"))
    assert campo_persistido["tipo_filtro"] == "igual"
  end

  # Lookup con checkbox (MetadataAppWeb.SelectorMultipleComponents,
  # 2026-08-27, a pedido explícito -- reemplaza el <select multiple>
  # nativo, no discoverable sin ctrl/cmd+click) para Defaults de un
  # parámetro "multi". meta_fixture_cliente_sucursal_id (referencia a
  # meta_schema_branch) es un campo real del fixture, sirve para probar
  # el lookup con opciones reales.
  test "el lookup de Defaults (tipo_filtro multi) marca/limpia todos via los botones, y checkboxes individuales via DOM real", %{conn: conn} do
    {header, consulta} = criar_consulta()

    campos =
      Enum.map(consulta.campos, fn c ->
        if c["campo"] == "meta_fixture_cliente_sucursal_id", do: Map.merge(c, %{"es_parametro" => true, "tipo_filtro" => "multi"}), else: c
      end)

    {:ok, consulta} = MetaConsultas.actualizar_campos(consulta, campos)
    id = "#{consulta.catalogo_base}::meta_fixture_cliente_sucursal_id"

    {:ok, view, _html} = live(conn, ~p"/sysadmin/bc-list/#{header.schema_context_name}/consulta")
    html = render_click(view, "cambiar_tab", %{"tab" => "get_config"})
    assert html =~ "Ninguno"

    html_todos = render_click(view, "marcar_defaults_todos", %{"campo" => id, "valores" => "1,2,3"})
    assert html_todos =~ "3 seleccionados" or html_todos =~ "Todos ("

    consulta_actualizada = MetaConsultas.obtener_por_header_id(header.id)
    campo_persistido = Enum.find(consulta_actualizada.campos, &(&1["campo"] == "meta_fixture_cliente_sucursal_id"))
    assert campo_persistido["defaults"]["valores"] == ["1", "2", "3"]

    html_limpio = render_click(view, "limpiar_defaults_valores", %{"campo" => id})
    assert html_limpio =~ "Ninguno"

    consulta_limpia = MetaConsultas.obtener_por_header_id(header.id)
    campo_limpio = Enum.find(consulta_limpia.campos, &(&1["campo"] == "meta_fixture_cliente_sucursal_id"))
    assert campo_limpio["defaults"]["valores"] == []
  end

  test "Tab Contrato documenta el endpoint real con un ejemplo de filtro", %{conn: conn} do
    {header, _consulta} = criar_consulta()

    {:ok, view, _html} = live(conn, ~p"/sysadmin/bc-list/#{header.schema_context_name}/consulta")

    html = render_click(view, "cambiar_tab", %{"tab" => "contrato"})

    assert html =~ "GET"
    assert html =~ "/api/#{header.schema_context_name}"
    assert html =~ "meta_fixture_cliente_nombre"
    assert html =~ "meta_campos"
    refute html =~ "Pendiente (Fase 3)"
  end

  test "Tab Permisos embebe CatalogoPermisosLive, solo lectura + alcance de datos como referencia al catálogo base", %{conn: conn} do
    {header, _consulta} = criar_consulta()

    {:ok, view, _html} = live(conn, ~p"/sysadmin/bc-list/#{header.schema_context_name}/consulta")

    html = render_click(view, "cambiar_tab", %{"tab" => "permisos"})

    assert html =~ "leer"
    refute html =~ "phx-value-accion=\"crear\""
    assert html =~ "Alcance de datos"
    assert html =~ "Una Consulta no tiene Alcance de Datos propio"
    assert html =~ "meta_fixture_cliente"
  end

  # El panel "Encabezado" es el mismo componente que usa BcMotorLive
  # (MetadataAppWeb.EncabezadoBcComponents, 2026-08-26) -- mismo UI/UX
  # (carpeta+segmento en vez de un input de URL libre, selector visual
  # de ícono) para que un catálogo y una Consulta se vean/editen igual.
  # Vive en el tab "Configuración" (movido ahí 2026-08-26, mismo lugar
  # que ocupa en BcMotorLive) -- que además es el tab activo por
  # default, así que ni hace falta cambiar de tab para verlo.
  test "Encabezado usa el mismo panel/eventos que BcMotorLive (carpeta+segmento, selector de ícono)", %{conn: conn} do
    {header, _consulta} = criar_consulta()

    {:ok, view, html} = live(conn, ~p"/sysadmin/bc-list/#{header.schema_context_name}/consulta")
    assert html =~ "Navegación:"
    assert html =~ "Ícono:"

    render_click(view, "elegir_icono_header", %{"icono" => "star"})

    html_guardado =
      view
      |> form("form[phx-submit=guardar_header]", %{"header" => %{"etiqueta" => "Consulta editada", "segmento" => "consulta-editada", "visible" => "true"}})
      |> render_submit()

    assert html_guardado =~ "Encabezado actualizado."

    header_actualizado = MetaSchemaContext.obtener_header_por_nombre(header.schema_context_name)
    assert header_actualizado.schema_context_label == "Consulta editada"
    assert header_actualizado.schema_context_nav == "/consulta-editada"
    assert header_actualizado.schema_context_icono == "star"
  end

  # Orden de tabs alineado a BcMotorLive (2026-08-26, a pedido explícito):
  # Configuración primero (tab activo por default, como allá), Get
  # Config al final, y un tab nuevo "SQL" después de ese.
  test "los tabs quedan en el mismo orden que BcMotorLive, con Configuración activo por default", %{conn: conn} do
    {header, _consulta} = criar_consulta()

    {:ok, _view, html} = live(conn, ~p"/sysadmin/bc-list/#{header.schema_context_name}/consulta")

    orden_esperado = ["Configuración", "Contrato", "Permisos", "Get Config", "SQL"]
    posiciones = Enum.map(orden_esperado, &:binary.match(html, &1))
    assert posiciones == Enum.sort_by(posiciones, &elem(&1, 0))

    assert html =~ "solo la etiqueta es editable"
  end

  test "Tab SQL muestra el SQL real y la Ecto.Query, de solo lectura, en 2 sub-tabs", %{conn: conn} do
    {header, _consulta} = criar_consulta()

    {:ok, view, _html} = live(conn, ~p"/sysadmin/bc-list/#{header.schema_context_name}/consulta")
    html_sql = render_click(view, "cambiar_tab", %{"tab" => "sql"})

    assert html_sql =~ "SELECT\n"
    assert html_sql =~ "\nFROM "
    assert html_sql =~ "meta_fixture_cliente"
    refute html_sql =~ "Ecto.Query&lt;"

    html_ecto = render_click(view, "cambiar_subtab_sql", %{"subtab" => "ecto"})
    assert html_ecto =~ "Ecto.Query&lt;"
  end

  # Tab SQL con Parámetro estándar configurado (2026-08-27, a pedido
  # explícito -- "quiero saber que se está filtrando") -- un campo
  # elegible SIN default real todavía muestra un WHERE con valor dummy
  # (100% informativo, MetaConsultas.query_representativa_con_filtros/1
  # nunca ejecuta contra la base de verdad), y un default YA configurado
  # se respeta tal cual, sin pisarlo con el dummy.
  test "Tab SQL muestra los WHERE de Parámetro estándar, con valor dummy si no hay default real todavía", %{conn: conn} do
    {header, consulta} = criar_consulta()

    campos =
      Enum.map(consulta.campos, fn c ->
        case c["campo"] do
          "meta_fixture_cliente_nombre" -> Map.put(c, "es_parametro", true)
          "meta_fixture_cliente_edad" -> Map.merge(c, %{"es_parametro" => true, "tipo_filtro" => "igual", "defaults" => %{"valor" => 42}})
          _ -> c
        end
      end)

    {:ok, _consulta} = MetaConsultas.actualizar_campos(consulta, campos)

    {:ok, view, _html} = live(conn, ~p"/sysadmin/bc-list/#{header.schema_context_name}/consulta")
    html_sql = render_click(view, "cambiar_tab", %{"tab" => "sql"})

    assert html_sql =~ "WHERE"
    assert html_sql =~ "valor de ejemplo"
    # meta_fixture_cliente_nombre (like, sin default) -> dummy "%ejemplo%"
    # meta_fixture_cliente_edad (igual, default real 42) -> 42, no un dummy
    # (comillas del inspect llegan HTML-escapadas como &quot; en el <pre>)
    assert html_sql =~ "ILIKE"
    assert html_sql =~ "%ejemplo%"
    assert html_sql =~ "42"
  end

  # "Orden de resultados" (R1 admin, 2026-08-27) -- pedido explícito:
  # poder ordenar el reporte por varias columnas en prioridad. Cualquier
  # campo de la consulta es elegible, visible o no (a diferencia de
  # Parámetro estándar).
  test "Orden de resultados: agregar, cambiar dirección, reordenar y quitar, todo persistido", %{conn: conn} do
    {header, _consulta} = criar_consulta()
    {:ok, view, _html} = live(conn, ~p"/sysadmin/bc-list/#{header.schema_context_name}/consulta")

    render_click(view, "cambiar_tab", %{"tab" => "get_config"})

    html = render_click(view, "abrir_selector_orden", %{})
    assert html =~ "Agregar columna de orden"

    html = render_click(view, "agregar_orden", %{"catalogo" => "meta_fixture_cliente", "campo" => "meta_fixture_cliente_edad"})
    assert html =~ "Ascendente"

    render_click(view, "abrir_selector_orden", %{})
    render_click(view, "agregar_orden", %{"catalogo" => "meta_fixture_cliente", "campo" => "meta_fixture_cliente_nombre"})

    consulta = MetaConsultas.obtener_por_header_id(header.id)
    assert Enum.map(consulta.orden_por, & &1["campo"]) == ~w(meta_fixture_cliente_edad meta_fixture_cliente_nombre)
    assert Enum.map(consulta.orden_por, & &1["direccion"]) == ~w(asc asc)

    html = render_click(view, "cambiar_direccion_orden", %{"indice" => "0"})
    assert html =~ "Descendente"
    consulta = MetaConsultas.obtener_por_header_id(header.id)
    assert Enum.at(consulta.orden_por, 0)["direccion"] == "desc"

    render_click(view, "mover_orden", %{"indice" => "1", "direccion" => "arriba"})
    consulta = MetaConsultas.obtener_por_header_id(header.id)
    assert Enum.map(consulta.orden_por, & &1["campo"]) == ~w(meta_fixture_cliente_nombre meta_fixture_cliente_edad)

    render_click(view, "quitar_orden", %{"indice" => "0"})
    consulta = MetaConsultas.obtener_por_header_id(header.id)
    assert Enum.map(consulta.orden_por, & &1["campo"]) == ~w(meta_fixture_cliente_edad)
  end

  test "un header que no es Consulta redirige a bc-list", %{conn: conn} do
    {:ok, {header, _}} =
      MetaSchemaContext.crear_header_con_detalles(%{
        "schema_context_name" => "no_es_consulta_#{unique()}",
        "schema_context_label" => "No es consulta",
        "schema_context_nav" => "/no_es_consulta_#{unique()}",
        "schema_visible" => true,
        "schema_context_type" => 1,
        "detalles" => []
      })

    assert {:error, {:live_redirect, %{to: "/sysadmin/bc-list"}}} =
             live(conn, ~p"/sysadmin/bc-list/#{header.schema_context_name}/consulta")
  end
end
