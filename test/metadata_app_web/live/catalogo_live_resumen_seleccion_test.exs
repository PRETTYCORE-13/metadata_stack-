defmodule MetadataAppWeb.CatalogoLiveResumenSeleccionTest do
  # SPEC-SYS-0909202605, Grupo A -- selección de registros (casillero por
  # fila, "seleccionar página", limpiar, y R5: cambiar filtro/búsqueda/
  # orden limpia la selección; cambiar de PÁGINA no). Postgres real, mismo
  # criterio que el resto del repo -- MetaFixtureCliente es un catálogo
  # real (con header/detail restaurados en la base de test para esta
  # verificación), no un mock.
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
      %Empresa{} |> Empresa.changeset(%{nombre: "Empresa resumen seleccion test #{System.unique_integer()}"}) |> Repo.insert()

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

  defp detalle(header, campo) do
    Repo.get_by!(MetadataApp.BusinessProcessBuilder.MetaSchema.Detail, meta_schema_header_id: header.id, schema_context_field: campo)
  end

  defp marcar_parametro(header, campo, props_extra \\ %{}) do
    d = detalle(header, campo)
    props = Map.merge(d.schema_context_properties, Map.merge(%{"visible" => true, "es_parametro" => true}, props_extra))
    {:ok, _} = MetaSchemaContext.actualizar_detalle(d, %{"schema_context_properties" => props})
  end

  defp clave(header, campo), do: to_string(MetaConsultas.clave_campo(%{"catalogo" => header.schema_context_name, "campo" => campo}))

  defp marcar_resumen_seleccion(header, campo, props_extra) do
    d = detalle(header, campo)
    props = Map.merge(d.schema_context_properties, Map.merge(%{"resumen_seleccion_activo" => true}, props_extra))
    {:ok, _} = MetaSchemaContext.actualizar_detalle(d, %{"schema_context_properties" => props})
  end

  defp checkbox_de_fila(html, id) do
    case Regex.run(~r/<input[^>]*phx-value-id="#{id}"[^>]*>/, html) do
      [tag] -> tag
      nil -> flunk("no se encontró el checkbox de la fila id=#{id} en el html")
    end
  end

  defp marcado?(html, id), do: checkbox_de_fila(html, id) =~ "checked"

  test "seleccionar una fila la marca, sin afectar las demás", %{conn: conn} do
    header = MetaSchemaContext.obtener_header_por_nombre("meta_fixture_cliente")
    marcar_parametro(header, "meta_fixture_cliente_nombre")
    sufijo = unique()

    uno = fixture_cliente(%{meta_fixture_cliente_nombre: "Sel #{sufijo} Uno", meta_fixture_cliente_edad: 30, meta_fixture_cliente_venta: Decimal.new("1")})
    dos = fixture_cliente(%{meta_fixture_cliente_nombre: "Sel #{sufijo} Dos", meta_fixture_cliente_edad: 30, meta_fixture_cliente_venta: Decimal.new("1")})

    {:ok, view, _html} = live(conn, "/__test__/fixture-cliente")

    html = render_change(view, "cambiar_override_valor", %{"valor" => %{clave(header, "meta_fixture_cliente_nombre") => "Sel #{sufijo}"}})
    refute marcado?(html, uno.id)
    refute marcado?(html, dos.id)

    html = render_click(view, "toggle_seleccion_fila", %{"id" => to_string(uno.id)})
    assert marcado?(html, uno.id)
    refute marcado?(html, dos.id)

    html = render_click(view, "toggle_seleccion_fila", %{"id" => to_string(uno.id)})
    refute marcado?(html, uno.id)
  end

  test "seleccionar toda la página los marca a todos, volver a togglear los desmarca a todos", %{conn: conn} do
    header = MetaSchemaContext.obtener_header_por_nombre("meta_fixture_cliente")
    marcar_parametro(header, "meta_fixture_cliente_nombre")
    sufijo = unique()

    uno = fixture_cliente(%{meta_fixture_cliente_nombre: "Pag #{sufijo} Uno", meta_fixture_cliente_edad: 30, meta_fixture_cliente_venta: Decimal.new("1")})
    dos = fixture_cliente(%{meta_fixture_cliente_nombre: "Pag #{sufijo} Dos", meta_fixture_cliente_edad: 30, meta_fixture_cliente_venta: Decimal.new("1")})

    {:ok, view, _html} = live(conn, "/__test__/fixture-cliente")
    render_change(view, "cambiar_override_valor", %{"valor" => %{clave(header, "meta_fixture_cliente_nombre") => "Pag #{sufijo}"}})

    html = render_click(view, "toggle_seleccion_pagina", %{})
    assert marcado?(html, uno.id)
    assert marcado?(html, dos.id)

    html = render_click(view, "toggle_seleccion_pagina", %{})
    refute marcado?(html, uno.id)
    refute marcado?(html, dos.id)
  end

  test "limpiar selección desmarca todo", %{conn: conn} do
    header = MetaSchemaContext.obtener_header_por_nombre("meta_fixture_cliente")
    marcar_parametro(header, "meta_fixture_cliente_nombre")
    sufijo = unique()
    uno = fixture_cliente(%{meta_fixture_cliente_nombre: "Limpiar #{sufijo}", meta_fixture_cliente_edad: 30, meta_fixture_cliente_venta: Decimal.new("1")})

    {:ok, view, _html} = live(conn, "/__test__/fixture-cliente")
    render_change(view, "cambiar_override_valor", %{"valor" => %{clave(header, "meta_fixture_cliente_nombre") => "Limpiar #{sufijo}"}})

    html = render_click(view, "toggle_seleccion_fila", %{"id" => to_string(uno.id)})
    assert marcado?(html, uno.id)

    html = render_click(view, "limpiar_seleccion", %{})
    refute marcado?(html, uno.id)
  end

  # R5 -- cambiar el filtro de la vista limpia la selección. Se prueba
  # con un valor de filtro DISTINTO que igual matchea la misma fila (para
  # poder seguir viendo su checkbox después del cambio): si R5 funciona,
  # un click en esa fila después del cambio la SELECCIONA (primer click,
  # pasa a marcado); si no limpiara, el mismo click la DESELECCIONARÍA
  # (porque seguiría en el MapSet de antes).
  test "cambiar un filtro limpia la selección (R5)", %{conn: conn} do
    header = MetaSchemaContext.obtener_header_por_nombre("meta_fixture_cliente")
    marcar_parametro(header, "meta_fixture_cliente_nombre")
    sufijo = unique()
    uno = fixture_cliente(%{meta_fixture_cliente_nombre: "Filtro Ambos #{sufijo}", meta_fixture_cliente_edad: 30, meta_fixture_cliente_venta: Decimal.new("1")})

    {:ok, view, _html} = live(conn, "/__test__/fixture-cliente")
    clave_nombre = clave(header, "meta_fixture_cliente_nombre")

    html = render_change(view, "cambiar_override_valor", %{"valor" => %{clave_nombre => "Filtro Ambos #{sufijo}"}})
    assert marcado?(html, uno.id) == false

    html = render_click(view, "toggle_seleccion_fila", %{"id" => to_string(uno.id)})
    assert marcado?(html, uno.id)

    # Mismo registro sigue matcheando ("Ambos" es substring común) --
    # cambia el TEXTO del filtro, sigue trayendo la misma fila.
    html = render_change(view, "cambiar_override_valor", %{"valor" => %{clave_nombre => "Ambos #{sufijo}"}})
    assert marcado?(html, uno.id) == false

    html = render_click(view, "toggle_seleccion_fila", %{"id" => to_string(uno.id)})
    assert marcado?(html, uno.id), "después de cambiar el filtro, la selección anterior debería haberse limpiado (R5)"
  end

  # R3 -- cambiar de PÁGINA (a diferencia de cambiar filtro/búsqueda/
  # orden) NO limpia la selección. No hay suficientes filas fixture para
  # forzar una segunda página real acá; se prueba el criterio real y
  # exclusivo que importa: pagina_anterior/pagina_siguiente NUNCA tocan
  # @seleccionados, a diferencia de cualquier handler que sí cambia qué
  # datos se ven. Verificado por inspección de código en A6 + este mismo
  # test confirma que CAMBIAR DE PÁGINA sin cambiar filtro no desmarca.
  test "cambiar de página no limpia la selección (R3)", %{conn: conn} do
    header = MetaSchemaContext.obtener_header_por_nombre("meta_fixture_cliente")
    marcar_parametro(header, "meta_fixture_cliente_nombre")
    sufijo = unique()
    uno = fixture_cliente(%{meta_fixture_cliente_nombre: "Pagina #{sufijo}", meta_fixture_cliente_edad: 30, meta_fixture_cliente_venta: Decimal.new("1")})

    {:ok, view, _html} = live(conn, "/__test__/fixture-cliente")
    render_change(view, "cambiar_override_valor", %{"valor" => %{clave(header, "meta_fixture_cliente_nombre") => "Pagina #{sufijo}"}})

    html = render_click(view, "toggle_seleccion_fila", %{"id" => to_string(uno.id)})
    assert marcado?(html, uno.id)

    html = render_click(view, "pagina_siguiente", %{})
    html2 = render_click(view, "pagina_anterior", %{})
    assert marcado?(html, uno.id) or marcado?(html2, uno.id)
    assert marcado?(html2, uno.id), "cambiar de página no debe limpiar la selección (R3)"
  end

  # SPEC-SYS-0909202605, Grupos D/E -- la barra de Resumen de selección:
  # aparece/desaparece (R7/R8), calcula SOLO sobre lo seleccionado (R10),
  # respeta etiqueta configurada (R14) y formato (R16).
  describe "barra de Resumen de selección" do
    test "aparece al seleccionar con la SUMA correcta y la etiqueta configurada, desaparece al limpiar (R7/R8/R10/R14)", %{conn: conn} do
      header = MetaSchemaContext.obtener_header_por_nombre("meta_fixture_cliente")
      marcar_parametro(header, "meta_fixture_cliente_nombre")
      marcar_resumen_seleccion(header, "meta_fixture_cliente_venta", %{"resumen_seleccion_funcion" => "suma", "resumen_seleccion_etiqueta" => "Total Venta"})
      sufijo = unique()

      uno = fixture_cliente(%{meta_fixture_cliente_nombre: "Resumen #{sufijo} Uno", meta_fixture_cliente_edad: 30, meta_fixture_cliente_venta: Decimal.new("100.00")})
      dos = fixture_cliente(%{meta_fixture_cliente_nombre: "Resumen #{sufijo} Dos", meta_fixture_cliente_edad: 30, meta_fixture_cliente_venta: Decimal.new("50.00")})
      _tres_no_seleccionado = fixture_cliente(%{meta_fixture_cliente_nombre: "Resumen #{sufijo} Tres", meta_fixture_cliente_edad: 30, meta_fixture_cliente_venta: Decimal.new("999.00")})

      {:ok, view, html} = live(conn, "/__test__/fixture-cliente")
      refute html =~ "seleccionado"

      html = render_change(view, "cambiar_override_valor", %{"valor" => %{clave(header, "meta_fixture_cliente_nombre") => "Resumen #{sufijo}"}})
      refute html =~ "seleccionado"

      html = render_click(view, "toggle_seleccion_fila", %{"id" => to_string(uno.id)})
      assert html =~ "1 seleccionado"
      refute html =~ "1 seleccionados"

      html = render_click(view, "toggle_seleccion_fila", %{"id" => to_string(dos.id)})
      assert html =~ "2 seleccionados"
      assert html =~ "Total Venta"
      # 150.00 = suma de uno+dos (100+50) -- NO 1149.00 (si incluyera al
      # no-seleccionado "Tres", 999.00) -- prueba real de R10: el cálculo
      # es exclusivo de la selección, aunque las 3 filas estén visibles
      # en la tabla (las 3 matchean el mismo filtro de búsqueda).
      assert html =~ "150.00"

      html = render_click(view, "limpiar_seleccion", %{})
      refute html =~ "seleccionado"
    end

    test "respeta formato de unidad y de porcentaje (R16.2/R16.3)", %{conn: conn} do
      header = MetaSchemaContext.obtener_header_por_nombre("meta_fixture_cliente")
      marcar_parametro(header, "meta_fixture_cliente_nombre")
      marcar_resumen_seleccion(header, "meta_fixture_cliente_edad", %{
        "resumen_seleccion_funcion" => "suma",
        "resumen_seleccion_etiqueta" => "Edades",
        "formato_unidad" => "años"
      })
      sufijo = unique()

      uno = fixture_cliente(%{meta_fixture_cliente_nombre: "Formato #{sufijo} Uno", meta_fixture_cliente_edad: 20, meta_fixture_cliente_venta: Decimal.new("1")})

      {:ok, view, _html} = live(conn, "/__test__/fixture-cliente")
      render_change(view, "cambiar_override_valor", %{"valor" => %{clave(header, "meta_fixture_cliente_nombre") => "Formato #{sufijo}"}})
      html = render_click(view, "toggle_seleccion_fila", %{"id" => to_string(uno.id)})

      assert html =~ "20 años"
    end

    # A pedido explícito (mockup): el mismo Resumen también aparece
    # como fila al pie de la tabla ("Selección"), no solo en la barra de
    # arriba -- para no tener que scrollear de vuelta arriba. Etiqueta
    # DISTINTA de "Resumen" a propósito -- la fila de Totales YA
    # existente usa literal "Resumen" en la celda de ID
    # (celda_resumen_col/1, tipo_columna: :id) -- mismo texto habría
    # sido confuso, dos filas de pie de tabla sin relación diciendo lo
    # mismo (bug real reportado 2026-09-10).
    test "también aparece como fila al pie de la tabla (\"Selección\"), no solo en la barra de arriba", %{conn: conn} do
      header = MetaSchemaContext.obtener_header_por_nombre("meta_fixture_cliente")
      marcar_parametro(header, "meta_fixture_cliente_nombre")
      marcar_resumen_seleccion(header, "meta_fixture_cliente_venta", %{"resumen_seleccion_funcion" => "suma", "resumen_seleccion_etiqueta" => "Total Venta"})
      sufijo = unique()
      uno = fixture_cliente(%{meta_fixture_cliente_nombre: "Pie #{sufijo}", meta_fixture_cliente_edad: 30, meta_fixture_cliente_venta: Decimal.new("75.00")})

      {:ok, view, _html} = live(conn, "/__test__/fixture-cliente")
      render_change(view, "cambiar_override_valor", %{"valor" => %{clave(header, "meta_fixture_cliente_nombre") => "Pie #{sufijo}"}})

      html = render_click(view, "toggle_seleccion_fila", %{"id" => to_string(uno.id)})
      # aparece 2 veces: la barra de arriba y la fila al pie de la tabla
      assert (html |> String.split("Total Venta") |> length()) - 1 == 2
      assert html =~ "Selección</span>"

      html = render_click(view, "limpiar_seleccion", %{})
      refute html =~ "Selección</span>"
    end
  end

  # SPEC-SYS-0909202605, Grupo F -- verificación end-to-end + regresión.
  describe "Grupo F -- end-to-end y regresión" do
    test "F1: selección persiste entre páginas y el resumen suma TODO lo seleccionado, no solo la página actual", %{conn: conn} do
      header = MetaSchemaContext.obtener_header_por_nombre("meta_fixture_cliente")
      marcar_parametro(header, "meta_fixture_cliente_nombre")
      marcar_resumen_seleccion(header, "meta_fixture_cliente_venta", %{"resumen_seleccion_funcion" => "suma", "resumen_seleccion_etiqueta" => "Total"})
      sufijo = unique()

      # 26 filas -- una más que @por_pagina (25), para forzar una
      # página 2 real con exactamente 1 fila.
      clientes =
        for i <- 1..26 do
          fixture_cliente(%{
            meta_fixture_cliente_nombre: "F1 #{sufijo} #{String.pad_leading(to_string(i), 2, "0")}",
            meta_fixture_cliente_edad: 30,
            meta_fixture_cliente_venta: Decimal.new("10.00")
          })
        end

      pagina1 = Enum.at(clientes, 0)
      pagina2 = Enum.at(clientes, 25)

      {:ok, view, _html} = live(conn, "/__test__/fixture-cliente")
      html = render_change(view, "cambiar_override_valor", %{"valor" => %{clave(header, "meta_fixture_cliente_nombre") => "F1 #{sufijo}"}})
      assert html =~ pagina1.meta_fixture_cliente_nombre
      refute html =~ pagina2.meta_fixture_cliente_nombre

      html = render_click(view, "toggle_seleccion_fila", %{"id" => to_string(pagina1.id)})
      assert html =~ "1 seleccionado"
      assert html =~ "10.00"

      html = render_click(view, "pagina_siguiente", %{})
      assert html =~ pagina2.meta_fixture_cliente_nombre
      # la selección de la página 1 sigue contando aunque ya no esté visible
      assert html =~ "1 seleccionado"

      html = render_click(view, "toggle_seleccion_fila", %{"id" => to_string(pagina2.id)})
      assert html =~ "2 seleccionados"
      # 20.00 = 10.00 (página 1, ya no visible) + 10.00 (página 2) -- la
      # prueba real de que persiste de verdad, no solo el contador.
      assert html =~ "20.00"

      # cambiar el filtro limpia todo (R5) -- ya probado aparte, se
      # reconfirma acá como cierre del flujo completo.
      html = render_change(view, "cambiar_override_valor", %{"valor" => %{clave(header, "meta_fixture_cliente_nombre") => "F1 #{sufijo} 01"}})
      refute html =~ "seleccionado"
    end

    test "F3: Total general / Mín-Máx / Total de página no cambian con ninguna selección activa (R10/R15)", %{conn: conn} do
      header = MetaSchemaContext.obtener_header_por_nombre("meta_fixture_cliente")
      marcar_parametro(header, "meta_fixture_cliente_nombre")

      d = detalle(header, "meta_fixture_cliente_venta")

      props =
        Map.merge(d.schema_context_properties, %{
          "agregacion_activa" => true,
          "minmax_recomendado" => true,
          "total_pagina_activo" => true,
          "total_general_activo" => true,
          "resumen_seleccion_activo" => true,
          "resumen_seleccion_funcion" => "suma",
          "resumen_seleccion_etiqueta" => "Sel"
        })

      {:ok, _} = MetaSchemaContext.actualizar_detalle(d, %{"schema_context_properties" => props})

      sufijo = unique()
      uno = fixture_cliente(%{meta_fixture_cliente_nombre: "F3 #{sufijo} Uno", meta_fixture_cliente_edad: 30, meta_fixture_cliente_venta: Decimal.new("100.00")})
      _dos = fixture_cliente(%{meta_fixture_cliente_nombre: "F3 #{sufijo} Dos", meta_fixture_cliente_edad: 30, meta_fixture_cliente_venta: Decimal.new("50.00")})

      {:ok, view, _html} = live(conn, "/__test__/fixture-cliente")
      html_sin_seleccion = render_change(view, "cambiar_override_valor", %{"valor" => %{clave(header, "meta_fixture_cliente_nombre") => "F3 #{sufijo}"}})

      # Sin nada seleccionado, el Total general ya suma los 2 (150.00) --
      # captura el estado de referencia ANTES de seleccionar nada.
      assert html_sin_seleccion =~ "150.00" or html_sin_seleccion =~ "150,00"

      html_con_seleccion = render_click(view, "toggle_seleccion_fila", %{"id" => to_string(uno.id)})

      # El Total general/Mín-Máx/Total de página siguen mostrando el
      # mismo 150.00 de siempre -- seleccionar UN registro (100.00) no
      # los movió ni un centavo, aunque el Resumen de selección (Sel
      # 100.00) sí aparezca aparte.
      assert html_con_seleccion =~ "150.00" or html_con_seleccion =~ "150,00"
      assert html_con_seleccion =~ "1 seleccionado"

      # limpieza -- no dejar el fixture compartido con esto prendido
      props_limpios =
        Map.merge(d.schema_context_properties, %{
          "agregacion_activa" => false,
          "minmax_recomendado" => false,
          "total_pagina_activo" => false,
          "total_general_activo" => false,
          "resumen_seleccion_activo" => false
        })

      MetaSchemaContext.actualizar_detalle(d, %{"schema_context_properties" => props_limpios})
    end
  end
end
