defmodule MetadataAppWeb.CatalogoLiveDescargarExcelTest do
  # SPEC-SYS-1009202601 -- "Descargar Excel" con menú de alcance (sin
  # selección: Todos/Página; con selección: Solo seleccionados (N)
  # primero, Todos, Página). Postgres real -- se decodifica el .xlsx
  # generado de verdad con Xlsxir (misma librería que ya usa
  # MetaImportacionDatos para LEER, acá se usa para verificar lo que
  # ESCRIBE construir_excel_export/2) en vez de solo confirmar que el
  # evento no revienta.
  use MetadataAppWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import MetadataApp.AutenticacionFixtures

  alias MetadataApp.Repo
  alias MetadataApp.Autenticacion.{Empresa, Rol, UsuarioEmpresa}
  alias MetadataApp.BusinessProcessBuilder.MetaSchemaContext
  alias MetadataApp.MetaBusinessProcess.Catalogos.MetaFixtureCliente
  alias MetadataApp.MetaConsultas
  alias MetadataApp.Permissions

  setup %{conn: conn} do
    usuario = usuario_fixture()

    {:ok, empresa} =
      %Empresa{} |> Empresa.changeset(%{nombre: "Empresa descargar excel test #{System.unique_integer()}"}) |> Repo.insert()

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
  defp unique, do: System.unique_integer([:positive])

  defp fixture_cliente(attrs) do
    %MetaFixtureCliente{}
    |> MetaFixtureCliente.changeset(attrs)
    |> Ecto.Changeset.put_change(:insert_guid, guid())
    |> Repo.insert!()
  end

  # Decodifica el href data: URI que push_event manda, lo escribe a un
  # archivo temporal y lo lee de vuelta con Xlsxir -- mismo mecanismo
  # que ya usa MetaImportacionDatos para leer un .xlsx subido, acá al
  # revés (leer lo que el propio sistema acaba de escribir).
  defp filas_del_excel(href) do
    "data:application/vnd.openxmlformats-officedocument.spreadsheetml.sheet;base64," <> b64 = href
    binario = Base.decode64!(b64)
    ruta = Path.join(System.tmp_dir!(), "test_descargar_excel_#{unique()}.xlsx")
    File.write!(ruta, binario)

    {:ok, tid} = Xlsxir.extract(ruta, 0)
    filas = Xlsxir.get_list(tid)
    Xlsxir.close(tid)
    File.rm(ruta)
    filas
  end

  # El orden de columnas del Excel sigue el de la tabla en pantalla
  # (ID primero si está visible, luego negocio) -- no se asume una
  # posición fija, se busca el valor en CUALQUIER celda de CUALQUIER
  # fila.
  defp contiene?(filas, valor), do: filas |> List.flatten() |> Enum.member?(valor)

  test "el menú solo ofrece \"Solo seleccionados\" cuando hay selección, con el contador correcto", %{conn: conn} do
    sufijo = unique()
    uno = fixture_cliente(%{meta_fixture_cliente_nombre: "Menu #{sufijo}", meta_fixture_cliente_edad: 30, meta_fixture_cliente_venta: Decimal.new("1")})

    {:ok, view, html} = live(conn, "/__test__/fixture-cliente")
    refute html =~ "Solo seleccionados"
    assert html =~ "Todos los resultados"
    assert html =~ "Página actual"

    html = render_click(view, "toggle_seleccion_fila", %{"id" => to_string(uno.id)})
    assert html =~ "Solo seleccionados (1)"
  end

  test "alcance \"seleccionados\" exporta EXACTAMENTE los ids marcados, ignorando el resto", %{conn: conn} do
    sufijo = unique()

    uno = fixture_cliente(%{meta_fixture_cliente_nombre: "Excel Sel #{sufijo} Uno", meta_fixture_cliente_edad: 11, meta_fixture_cliente_venta: Decimal.new("1")})
    dos = fixture_cliente(%{meta_fixture_cliente_nombre: "Excel Sel #{sufijo} Dos", meta_fixture_cliente_edad: 22, meta_fixture_cliente_venta: Decimal.new("1")})
    _tres = fixture_cliente(%{meta_fixture_cliente_nombre: "Excel Sel #{sufijo} Tres", meta_fixture_cliente_edad: 33, meta_fixture_cliente_venta: Decimal.new("1")})

    {:ok, view, _html} = live(conn, "/__test__/fixture-cliente")
    render_click(view, "toggle_seleccion_fila", %{"id" => to_string(uno.id)})
    render_click(view, "toggle_seleccion_fila", %{"id" => to_string(dos.id)})

    render_click(view, "descargar_excel", %{"alcance" => "seleccionados"})
    assert_push_event(view, "descargar-archivo", %{href: href})

    filas = filas_del_excel(href)
    assert contiene?(filas, uno.meta_fixture_cliente_nombre)
    assert contiene?(filas, dos.meta_fixture_cliente_nombre)
    refute contiene?(filas, "Excel Sel #{sufijo} Tres")
    # 2 seleccionados + fila de etiquetas + fila TOTAL
    assert length(filas) == 4
  end

  test "alcance \"pagina\" exporta solo @filas ya cargadas (mismo criterio que \"Total 25\")", %{conn: conn} do
    sufijo = unique()
    uno = fixture_cliente(%{meta_fixture_cliente_nombre: "Excel Pag #{sufijo}", meta_fixture_cliente_edad: 30, meta_fixture_cliente_venta: Decimal.new("1")})

    {:ok, view, _html} = live(conn, "/__test__/fixture-cliente")
    render_change(view, "buscar_general", %{"value" => "Excel Pag #{sufijo}"})

    render_click(view, "descargar_excel", %{"alcance" => "pagina"})
    assert_push_event(view, "descargar-archivo", %{href: href})

    assert contiene?(filas_del_excel(href), uno.meta_fixture_cliente_nombre)
  end

  test "alcance \"todos\" sigue funcionando igual que antes (regresión)", %{conn: conn} do
    sufijo = unique()
    uno = fixture_cliente(%{meta_fixture_cliente_nombre: "Excel Todos #{sufijo}", meta_fixture_cliente_edad: 30, meta_fixture_cliente_venta: Decimal.new("1")})

    {:ok, view, _html} = live(conn, "/__test__/fixture-cliente")
    render_change(view, "buscar_general", %{"value" => "Excel Todos #{sufijo}"})
    render_click(view, "descargar_excel", %{"alcance" => "todos"})
    assert_push_event(view, "descargar-archivo", %{href: href})

    assert contiene?(filas_del_excel(href), uno.meta_fixture_cliente_nombre)
  end

  # SPEC-SYS-1009202601 -- bug real preexistente: "Descargar Excel" en
  # una Consulta crasheaba SIEMPRE con KeyError (assigns.columnas_render
  # no existe ahí) -- nunca se había probado antes de esta spec.
  test "Descargar Excel funciona en una Consulta (bug real corregido), incluido el alcance \"seleccionados\"", %{conn: conn} do
    nav = "/excel_consulta_test_#{unique()}"

    {:ok, {header, _}} =
      MetaSchemaContext.crear_header_con_detalles(%{
        "schema_context_name" => "excel_consulta_test_#{unique()}",
        "schema_context_label" => "Excel consulta test",
        "schema_context_nav" => nav,
        "schema_visible" => true,
        "schema_context_type" => 3,
        "detalles" => []
      })

    {:ok, _consulta} = MetaConsultas.crear(header, "meta_fixture_cliente")
    {:ok, _} = Permissions.crear_permiso(%{recurso: header.schema_context_name, accion: "leer"})

    sufijo = unique()
    uno = fixture_cliente(%{meta_fixture_cliente_nombre: "Excel Consulta #{sufijo}", meta_fixture_cliente_edad: 30, meta_fixture_cliente_venta: Decimal.new("1")})

    {:ok, view, _html} = live(conn, nav)
    render_change(view, "buscar_general", %{"value" => "Excel Consulta #{sufijo}"})

    render_click(view, "descargar_excel", %{"alcance" => "todos"})
    assert_push_event(view, "descargar-archivo", %{href: href_todos})
    assert contiene?(filas_del_excel(href_todos), uno.meta_fixture_cliente_nombre)

    render_click(view, "toggle_seleccion_fila", %{"id" => to_string(uno.id)})
    render_click(view, "descargar_excel", %{"alcance" => "seleccionados"})
    assert_push_event(view, "descargar-archivo", %{href: href_sel})
    filas_sel = filas_del_excel(href_sel)
    # 1 seleccionado + fila de etiquetas + fila TOTAL
    assert length(filas_sel) == 3
    assert contiene?(filas_sel, uno.meta_fixture_cliente_nombre)
  end
end
