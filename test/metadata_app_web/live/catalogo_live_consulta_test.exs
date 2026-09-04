defmodule MetadataAppWeb.CatalogoLiveConsultaTest do
  use MetadataAppWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias MetadataApp.Repo
  alias MetadataApp.Autenticacion
  alias MetadataApp.Autenticacion.{Empresa, Rol, UsuarioEmpresa}
  alias MetadataApp.BusinessProcessBuilder.MetaSchemaContext
  alias MetadataApp.MetaBusinessProcess.Catalogos.MetaFixtureCliente
  alias MetadataApp.MetaConsultas
  alias MetadataApp.Permissions

  import MetadataApp.AutenticacionFixtures

  # Consulta Ecto (schema_context_type: 3) sobre el catálogo fixture
  # meta_fixture_cliente — mismo criterio que meta_transicion_controller_test:
  # administrador ve cualquier permiso YA REGISTRADO sin rol_permiso
  # explícito, así que alcanza con loguearse como tal y registrar el "leer"
  # de la consulta (nadie lo hace automático al crearla, ver
  # CatalogoPermisosLive/buscar_catalogos/2).
  setup %{conn: conn} do
    usuario = usuario_fixture()

    {:ok, empresa} =
      %Empresa{} |> Empresa.changeset(%{nombre: "Empresa consulta test #{System.unique_integer()}"}) |> Repo.insert()

    {:ok, _} =
      %UsuarioEmpresa{} |> UsuarioEmpresa.changeset(%{usuario_id: usuario.id, empresa_id: empresa.id}) |> Repo.insert()

    rol_admin = Repo.get_by!(Rol, nombre: "administrador")
    {:ok, _} = Permissions.asignar_rol(usuario.id, rol_admin.id, empresa.id)

    conn =
      conn
      |> log_in_usuario(usuario)
      |> Plug.Conn.put_session(:empresa_activa_id, empresa.id)

    %{conn: conn, empresa: empresa}
  end

  defp guid, do: Ecto.UUID.generate() |> String.replace("-", "")
  defp unique, do: System.unique_integer([:positive])

  defp fixture_cliente(attrs) do
    %MetaFixtureCliente{}
    |> MetaFixtureCliente.changeset(attrs)
    |> Ecto.Changeset.put_change(:insert_guid, guid())
    |> Repo.insert!()
  end

  defp criar_consulta_sobre_fixture do
    nav = "/consulta_fixture_test_#{unique()}"
    nombre = "consulta_fixture_test_#{unique()}"

    {:ok, {header, _detalles}} =
      MetaSchemaContext.crear_header_con_detalles(%{
        "schema_context_name" => nombre,
        "schema_context_label" => "Consulta fixture de prueba",
        "schema_context_nav" => nav,
        "schema_visible" => true,
        "schema_context_type" => 3,
        "detalles" => []
      })

    {:ok, consulta} = MetaConsultas.crear(header, "meta_fixture_cliente")
    {:ok, _} = Permissions.crear_permiso(%{recurso: nombre, accion: "leer"})

    {header, consulta, nav}
  end

  test "monta la consulta sin traer datos hasta que se aplique un filtro", %{conn: conn} do
    fixture_cliente(%{
      meta_fixture_cliente_nombre: "Cliente Uno #{unique()}",
      meta_fixture_cliente_edad: 30,
      meta_fixture_cliente_venta: Decimal.new("100.00")
    })

    cliente_dos =
      fixture_cliente(%{
        meta_fixture_cliente_nombre: "Cliente Dos #{unique()}",
        meta_fixture_cliente_edad: 45,
        meta_fixture_cliente_venta: Decimal.new("250.00")
      })

    {_header, consulta, nav} = criar_consulta_sobre_fixture()

    campos =
      Enum.map(consulta.campos, fn c ->
        if c["campo"] == "meta_fixture_cliente_nombre", do: Map.put(c, "es_parametro", true), else: c
      end)

    {:ok, consulta} = MetaConsultas.actualizar_campos(consulta, campos)

    {:ok, view, html} = live(conn, nav)

    assert html =~ "Consulta fixture de prueba"
    refute html =~ cliente_dos.meta_fixture_cliente_nombre
    refute html =~ "Cliente Uno"

    clave = to_string(MetaConsultas.clave_campo(Enum.find(consulta.campos, &(&1["campo"] == "meta_fixture_cliente_nombre"))))

    html_filtrado =
      view
      |> render_change("cambiar_override_valor", %{"valor" => %{clave => cliente_dos.meta_fixture_cliente_nombre}})

    assert html_filtrado =~ cliente_dos.meta_fixture_cliente_nombre
    refute html_filtrado =~ "Cliente Uno"
  end

  # Bug real (2026-08-26): una Consulta con una columna tipo "referencia"
  # visible reventaba con ArgumentError al montar la página --
  # columna_desde_campo_consulta/1 solo copiaba "etiqueta"/"tipo" a
  # schema_context_properties, sin "catalogo" (el destino real de la
  # referencia). El widget de "Parámetros" (panel_parametros/1) llama
  # CatalogoGenerico.opciones_referencia/1 para un campo "referenciado",
  # que terminaba comparando "schema_context_name == nil" en Ecto --
  # prohibido, ArgumentError. meta_fixture_cliente_sucursal_id (referencia
  # a meta_schema_branch, catálogo de sistema) es el campo agregado a
  # propósito para poder reproducir esto con un fixture real.
  test "una columna tipo referencia no revienta al montar (resuelve el catálogo destino real)", %{conn: conn} do
    {_header, consulta, nav} = criar_consulta_sobre_fixture()

    campos =
      Enum.map(consulta.campos, fn c ->
        if c["campo"] == "meta_fixture_cliente_sucursal_id", do: Map.put(c, "es_parametro", true), else: c
      end)

    {:ok, _} = MetaConsultas.actualizar_campos(consulta, campos)

    {:ok, _view, html} = live(conn, nav)

    assert html =~ "Sucursal"
    refute html =~ "ArgumentError"
  end

  test "la banda de totales suma solo la columna marcada totalizar, una vez que hay búsqueda activa", %{conn: conn} do
    fixture_cliente(%{meta_fixture_cliente_nombre: "A #{unique()}", meta_fixture_cliente_edad: 10, meta_fixture_cliente_venta: Decimal.new("1")})
    fixture_cliente(%{meta_fixture_cliente_nombre: "B #{unique()}", meta_fixture_cliente_edad: 20, meta_fixture_cliente_venta: Decimal.new("1")})

    {_header, consulta, nav} = criar_consulta_sobre_fixture()

    campos =
      Enum.map(consulta.campos, fn c ->
        if c["campo"] == "meta_fixture_cliente_edad",
          do: Map.merge(c, %{"agregacion_activa" => true, "total_general_activo" => true}),
          else: c
      end)

    {:ok, _} = MetaConsultas.actualizar_campos(consulta, campos)

    {:ok, view, _html} = live(conn, nav)

    html = view |> render_change("buscar_general", %{"value" => "A"})

    assert html =~ "Totalizado: 10"
  end

  # Mismo bug real que la prueba de arriba, pero vía el widget de
  # Parámetros (overrides_parametro) en vez de la búsqueda general —
  # MetaConsultas.agregar/5 no aplicaba ParametrosCatalogo.
  # aplicar_filtros_parametro_estandar/4 aunque contar/5 y ejecutar/6 sí
  # lo hacían, así que "Totalizado" sumaba las filas de TODA la consulta.
  test "la banda de totales respeta un parámetro activo, no solo la búsqueda general", %{conn: conn} do
    fixture_cliente(%{meta_fixture_cliente_nombre: "Gina Vega #{unique()}", meta_fixture_cliente_edad: 10, meta_fixture_cliente_venta: Decimal.new("1")})
    fixture_cliente(%{meta_fixture_cliente_nombre: "Hugo Vega #{unique()}", meta_fixture_cliente_edad: 20, meta_fixture_cliente_venta: Decimal.new("1")})

    {_header, consulta, nav} = criar_consulta_sobre_fixture()

    campos =
      Enum.map(consulta.campos, fn c ->
        cond do
          c["campo"] == "meta_fixture_cliente_edad" -> Map.merge(c, %{"agregacion_activa" => true, "total_general_activo" => true})
          c["campo"] == "meta_fixture_cliente_nombre" -> Map.put(c, "es_parametro", true)
          true -> c
        end
      end)

    {:ok, consulta} = MetaConsultas.actualizar_campos(consulta, campos)

    {:ok, view, _html} = live(conn, nav)

    clave = to_string(MetaConsultas.clave_campo(Enum.find(consulta.campos, &(&1["campo"] == "meta_fixture_cliente_nombre"))))

    html = render_change(view, "cambiar_override_valor", %{"valor" => %{clave => "Gina Vega"}})

    assert html =~ "Totalizado: 10"
    refute html =~ "Totalizado: 30"
  end

  # Barra de "Parámetros" (rediseño 2026-08-27, corregido el mismo día --
  # ver moduledoc de MetaSchema.Consulta) -- opt-in: el admin tiene que
  # marcar "es_parametro" => true a propósito por columna en Get Config,
  # ninguna aparece sola por ser de tipo elegible. Aparte del popover de
  # Filtros genérico de siempre. meta_fixture_cliente_sucursal_id
  # (referencia a meta_schema_branch) es el mismo campo agregado antes
  # para el bug de referencia -- sirve igual acá para probar el
  # multi-select nativo de verdad.
  test "la barra de Parámetros no aparece si ninguna columna tiene \"es_parametro\" marcado", %{conn: conn} do
    {_header, _consulta, nav} = criar_consulta_sobre_fixture()

    {:ok, _view, html} = live(conn, nav)

    refute html =~ "Parámetros"
  end

  test "el multi-select de un campo referencia en la barra de Parámetros filtra por igualdad múltiple", %{conn: conn, empresa: empresa} do
    {:ok, branch_a} = Autenticacion.crear_branch(%{empresa_id: empresa.id, branch_name: "Sucursal A #{unique()}"})
    {:ok, branch_b} = Autenticacion.crear_branch(%{empresa_id: empresa.id, branch_name: "Sucursal B #{unique()}"})

    cliente_a =
      fixture_cliente(%{
        meta_fixture_cliente_nombre: "Cliente A #{unique()}",
        meta_fixture_cliente_edad: 30,
        meta_fixture_cliente_venta: Decimal.new("1"),
        meta_fixture_cliente_sucursal_id: branch_a.id
      })

    cliente_b =
      fixture_cliente(%{
        meta_fixture_cliente_nombre: "Cliente B #{unique()}",
        meta_fixture_cliente_edad: 30,
        meta_fixture_cliente_venta: Decimal.new("1"),
        meta_fixture_cliente_sucursal_id: branch_b.id
      })

    {_header, consulta, nav} = criar_consulta_sobre_fixture()

    campos =
      Enum.map(consulta.campos, fn c ->
        if c["campo"] == "meta_fixture_cliente_sucursal_id", do: Map.merge(c, %{"es_parametro" => true, "tipo_filtro" => "multi"}), else: c
      end)

    {:ok, consulta} = MetaConsultas.actualizar_campos(consulta, campos)
    campo_sucursal = Enum.find(consulta.campos, &(&1["campo"] == "meta_fixture_cliente_sucursal_id"))
    clave = to_string(MetaConsultas.clave_campo(campo_sucursal))

    {:ok, view, html} = live(conn, nav)
    assert html =~ "Parámetros"
    assert html =~ branch_a.branch_name
    assert html =~ branch_b.branch_name

    # DOM real (element/2 + render_change/2), no dispatch crudo -- el
    # checkbox tiene su propio phx-change (form="form-parametros-reporte"),
    # así que el payload real solo trae ESE name (onlyNames en pushInput);
    # todos los checkboxes de este lookup comparten el mismo name, así
    # que en un navegador real vendrían TODOS los tildados juntos -- acá
    # se simula pasando la lista completa a mano (mismo criterio que ya
    # usan los demás tests DOM-realistas de esta sesión).
    html_filtrado =
      view
      |> element("input[type=\"checkbox\"][name=\"valores[#{clave}][]\"][value=\"#{branch_a.id}\"]")
      |> render_change(%{"valores" => %{clave => [to_string(branch_a.id)]}})

    assert html_filtrado =~ cliente_a.meta_fixture_cliente_nombre
    refute html_filtrado =~ cliente_b.meta_fixture_cliente_nombre

    # Botón "Ninguno" -- limpia la selección (click, sin form/phx-value
    # raros: mismo patrón ya probado que "cambiar_defaults_modo").
    html_limpio = render_click(view, "limpiar_override_valores", %{"campo" => clave})
    assert html_limpio =~ cliente_a.meta_fixture_cliente_nombre
    assert html_limpio =~ cliente_b.meta_fixture_cliente_nombre
  end

  test "un parámetro string \"contiene\" (like) filtra por coincidencia parcial desde la barra de Parámetros", %{conn: conn} do
    cliente_uno = fixture_cliente(%{meta_fixture_cliente_nombre: "Panadería Central #{unique()}", meta_fixture_cliente_edad: 1, meta_fixture_cliente_venta: Decimal.new("1")})
    cliente_dos = fixture_cliente(%{meta_fixture_cliente_nombre: "Ferretería Norte #{unique()}", meta_fixture_cliente_edad: 1, meta_fixture_cliente_venta: Decimal.new("1")})

    {_header, consulta, nav} = criar_consulta_sobre_fixture()

    campos =
      Enum.map(consulta.campos, fn c ->
        if c["campo"] == "meta_fixture_cliente_nombre", do: Map.put(c, "es_parametro", true), else: c
      end)

    {:ok, consulta} = MetaConsultas.actualizar_campos(consulta, campos)
    campo_nombre = Enum.find(consulta.campos, &(&1["campo"] == "meta_fixture_cliente_nombre"))
    clave = to_string(MetaConsultas.clave_campo(campo_nombre))

    {:ok, view, _html} = live(conn, nav)

    html_filtrado =
      view
      |> element("input[name=\"valor[#{clave}]\"]")
      |> render_change(%{"valor" => %{clave => "Panader"}})

    assert html_filtrado =~ cliente_uno.meta_fixture_cliente_nombre
    refute html_filtrado =~ cliente_dos.meta_fixture_cliente_nombre
  end

  # El default de fecha vive en Get Config (Consulta.campos, admin) --
  # cambiarlo desde acá (usuario final) es SOLO de esta sesión, nunca
  # pisa ese default guardado. "fecha_registro" YA es un campo real de
  # meta_fixture_cliente (meta_schema_detail, ver priv/repo/catalogos/
  # meta_fixture_cliente.meta.json) -- criar_consulta_sobre_fixture/0 ya
  # lo trae solo en consulta.campos, así que acá se actualiza ESE campo
  # (Enum.map, mismo patrón que el resto de los tests de este archivo)
  # en vez de agregar uno nuevo -- bug real 2026-08-27: agregarlo de
  # nuevo duplicaba el campo (mismo catalogo+campo, mismo id de columna)
  # y LiveView reventaba en el test con "Duplicate id found" apenas se
  # armó el ícono de filtro por columna (cada uno con un id propio
  # derivado de catalogo+campo).
  test "cambiar el modo de un parámetro Fecha desde el reporte no persiste el default de Get Config", %{conn: conn} do
    cliente =
      fixture_cliente(%{meta_fixture_cliente_nombre: "Con fecha #{unique()}", meta_fixture_cliente_edad: 1, meta_fixture_cliente_venta: Decimal.new("1")})
      |> Ecto.Changeset.change(fecha_registro: DateTime.new!(~D[2026-01-15], ~T[12:00:00], "Etc/UTC"))
      |> Repo.update!()

    {_header, consulta, nav} = criar_consulta_sobre_fixture()

    campos =
      Enum.map(consulta.campos, fn c ->
        if c["campo"] == "fecha_registro" do
          Map.merge(c, %{
            "visible" => true,
            "es_parametro" => true,
            "acotado" => true,
            "defaults" => %{"modo" => "formula", "valor" => "2000-01-01", "valor_hasta" => "2000-01-02"}
          })
        else
          c
        end
      end)

    {:ok, consulta} = MetaConsultas.actualizar_campos(consulta, campos)
    campo_fecha = Enum.find(consulta.campos, &(&1["campo"] == "fecha_registro"))

    {:ok, view, html} = live(conn, nav)
    assert html =~ "Parámetros"
    refute html =~ cliente.meta_fixture_cliente_nombre

    clave = to_string(MetaConsultas.clave_campo(campo_fecha))

    view |> element("input[name=\"valor[#{clave}]\"]") |> render_change(%{"valor" => %{clave => "2026-01-01"}})

    html_filtrado =
      view
      |> element("input[name=\"valor_hasta[#{clave}]\"]")
      |> render_change(%{"valor_hasta" => %{clave => "2026-02-01"}})

    assert html_filtrado =~ cliente.meta_fixture_cliente_nombre

    consulta_sin_tocar = MetaConsultas.obtener_por_header_id(consulta.meta_schema_header_id)
    campo_persistido = Enum.find(consulta_sin_tocar.campos, &(&1["campo"] == "fecha_registro"))
    assert campo_persistido["defaults"]["valor"] == "2000-01-01"
    assert campo_persistido["defaults"]["valor_hasta"] == "2000-01-02"
  end

  # "Orden de resultados" (R2, usuario final, 2026-08-27) -- clic en el
  # encabezado ordena SOLO la sesión, nunca pisa "Orden de resultados" que
  # haya configurado el admin en Get Config (@orden_usuario, socket-only).
  test "clic en un encabezado ordena la sesión (asc -> desc -> vuelve al default), sin persistir nada", %{conn: conn} do
    prefijo = "ordenclic_#{unique()}"
    fixture_cliente(%{meta_fixture_cliente_nombre: "#{prefijo}-b", meta_fixture_cliente_edad: 30, meta_fixture_cliente_venta: Decimal.new("1")})
    fixture_cliente(%{meta_fixture_cliente_nombre: "#{prefijo}-a", meta_fixture_cliente_edad: 10, meta_fixture_cliente_venta: Decimal.new("1")})

    {_header, consulta, nav} = criar_consulta_sobre_fixture()

    {:ok, view, _html} = live(conn, nav)
    view |> render_change("buscar_general", %{"value" => prefijo})

    html_asc = view |> render_click("ordenar_por_columna", %{"catalogo" => "meta_fixture_cliente", "campo" => "meta_fixture_cliente_edad"})
    assert String.contains?(html_asc, "#{prefijo}-a") and String.contains?(html_asc, "#{prefijo}-b")
    assert :binary.match(html_asc, "#{prefijo}-a") |> elem(0) < (:binary.match(html_asc, "#{prefijo}-b") |> elem(0))

    html_desc = view |> render_click("ordenar_por_columna", %{"catalogo" => "meta_fixture_cliente", "campo" => "meta_fixture_cliente_edad"})
    assert :binary.match(html_desc, "#{prefijo}-b") |> elem(0) < (:binary.match(html_desc, "#{prefijo}-a") |> elem(0))

    # 3er clic en la MISMA columna vuelve al default del admin (nil) -- sin
    # ninguna columna de orden configurada en Get Config, no hay garantía
    # de posición, así que acá solo se confirma que la flecha de orden
    # desaparece del encabezado, no un orden de filas puntual.
    html_default = view |> render_click("ordenar_por_columna", %{"catalogo" => "meta_fixture_cliente", "campo" => "meta_fixture_cliente_edad"})
    refute html_default =~ "▲"
    refute html_default =~ "▼"

    consulta_sin_tocar = MetaConsultas.obtener_por_header_id(consulta.meta_schema_header_id)
    assert consulta_sin_tocar.orden_por == []
  end
end
