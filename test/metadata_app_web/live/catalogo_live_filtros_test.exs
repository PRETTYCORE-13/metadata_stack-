defmodule MetadataAppWeb.CatalogoLiveFiltrosTest do
  @moduledoc """
  SPEC-SYS-0209202601, Grupo F -- el ícono de embudo por columna
  (panel_filtros/1, fila_filtro_columna/1) se retiró. Un catálogo (BC)
  normal filtra desde panel_parametros/1 -- el mismo widget "Parámetros"
  que ya tenía una Consulta Ecto -- y solo para columnas que el admin
  marcó "es_parametro" en Get Config (bc_motor_live.ex). Sin ese flag,
  el panel ni aparece (ver campos_param_de_catalogo/2 en catalogo_live.ex).
  """
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
      %Empresa{} |> Empresa.changeset(%{nombre: "Empresa filtros test #{System.unique_integer()}"}) |> Repo.insert()

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

  # Mismo criterio que bc_motor_live_parametros_test.exs -- "visible" es
  # requisito para poder ser Parámetro (misma barrera que Consultas).
  defp marcar_parametro(header, campo, props_extra \\ %{}) do
    d = detalle(header, campo)
    props = Map.merge(d.schema_context_properties, Map.merge(%{"visible" => true, "es_parametro" => true}, props_extra))
    {:ok, _} = MetaSchemaContext.actualizar_detalle(d, %{"schema_context_properties" => props})
  end

  defp clave(header, campo), do: to_string(MetaConsultas.clave_campo(%{"catalogo" => header.schema_context_name, "campo" => campo}))

  test "un campo NO marcado Parámetro no ofrece ningún widget de filtro al usuario final", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/__test__/fixture-cliente")

    refute html =~ "Parámetros"
  end

  test "un campo marcado Parámetro filtra la tabla contra datos reales", %{conn: conn} do
    header = MetaSchemaContext.obtener_header_por_nombre("meta_fixture_cliente")
    marcar_parametro(header, "meta_fixture_cliente_nombre")

    sufijo = unique()

    ana =
      fixture_cliente(%{
        meta_fixture_cliente_nombre: "Ana Torres #{sufijo}",
        meta_fixture_cliente_edad: 30,
        meta_fixture_cliente_venta: Decimal.new("1")
      })

    beto =
      fixture_cliente(%{
        meta_fixture_cliente_nombre: "Beto Torres #{sufijo}",
        meta_fixture_cliente_edad: 30,
        meta_fixture_cliente_venta: Decimal.new("1")
      })

    {:ok, view, html} = live(conn, "/__test__/fixture-cliente")

    assert html =~ "Parámetros"
    # Sin filtro/búsqueda todavía, la tabla no trae datos (carga diferida,
    # ver datos_solicitados?/1) — ninguno de los dos nombres aparece.
    refute html =~ ana.meta_fixture_cliente_nombre
    refute html =~ beto.meta_fixture_cliente_nombre

    html_filtrado =
      render_change(view, "cambiar_override_valor", %{"valor" => %{clave(header, "meta_fixture_cliente_nombre") => "Ana Torres #{sufijo}"}})

    assert html_filtrado =~ ana.meta_fixture_cliente_nombre
    refute html_filtrado =~ beto.meta_fixture_cliente_nombre
  end

  test "dos parámetros (texto + rango numérico) combinan con AND, no solo el último", %{conn: conn} do
    header = MetaSchemaContext.obtener_header_por_nombre("meta_fixture_cliente")
    marcar_parametro(header, "meta_fixture_cliente_nombre")
    marcar_parametro(header, "meta_fixture_cliente_edad", %{"acotado" => true})

    sufijo = unique()
    clave_nombre = clave(header, "meta_fixture_cliente_nombre")
    clave_edad = clave(header, "meta_fixture_cliente_edad")

    # Matchea AMBOS parámetros (nombre "Ana<sufijo>" + edad 25-35).
    coincide =
      fixture_cliente(%{meta_fixture_cliente_nombre: "Ana#{sufijo} Uno", meta_fixture_cliente_edad: 30, meta_fixture_cliente_venta: Decimal.new("1")})

    # Nombre matchea, edad NO (45 fuera de 25-35).
    nombre_ok_edad_no =
      fixture_cliente(%{meta_fixture_cliente_nombre: "Ana#{sufijo} Dos", meta_fixture_cliente_edad: 45, meta_fixture_cliente_venta: Decimal.new("1")})

    # Edad matchea, nombre NO ("Beto" no contiene "Ana").
    edad_ok_nombre_no =
      fixture_cliente(%{meta_fixture_cliente_nombre: "Beto#{sufijo} Tres", meta_fixture_cliente_edad: 30, meta_fixture_cliente_venta: Decimal.new("1")})

    {:ok, view, _html} = live(conn, "/__test__/fixture-cliente")

    render_change(view, "cambiar_override_valor", %{"valor" => %{clave_nombre => "Ana#{sufijo}"}})
    render_change(view, "cambiar_override_valor", %{"valor" => %{clave_edad => "25"}})
    html = render_change(view, "cambiar_override_valor_hasta", %{"valor_hasta" => %{clave_edad => "35"}})

    assert html =~ coincide.meta_fixture_cliente_nombre
    refute html =~ nombre_ok_edad_no.meta_fixture_cliente_nombre
    refute html =~ edad_ok_nombre_no.meta_fixture_cliente_nombre
  end

  test "limpiar el override de un parámetro lo saca del filtro pero el otro sigue activo", %{conn: conn} do
    header = MetaSchemaContext.obtener_header_por_nombre("meta_fixture_cliente")
    marcar_parametro(header, "meta_fixture_cliente_nombre")
    marcar_parametro(header, "meta_fixture_cliente_edad", %{"acotado" => true})

    sufijo = unique()
    clave_nombre = clave(header, "meta_fixture_cliente_nombre")
    clave_edad = clave(header, "meta_fixture_cliente_edad")

    solo_nombre =
      fixture_cliente(%{meta_fixture_cliente_nombre: "Carla Ruiz #{sufijo}", meta_fixture_cliente_edad: 99, meta_fixture_cliente_venta: Decimal.new("1")})

    otro =
      fixture_cliente(%{meta_fixture_cliente_nombre: "Dana Ruiz #{sufijo}", meta_fixture_cliente_edad: 1, meta_fixture_cliente_venta: Decimal.new("1")})

    {:ok, view, _html} = live(conn, "/__test__/fixture-cliente")

    render_change(view, "cambiar_override_valor", %{"valor" => %{clave_nombre => "Ruiz #{sufijo}"}})
    render_change(view, "cambiar_override_valor", %{"valor" => %{clave_edad => "90"}})
    render_change(view, "cambiar_override_valor_hasta", %{"valor_hasta" => %{clave_edad => "100"}})

    # Se borra SOLO el rango de edad (vuelve a texto vacío) — el de
    # nombre queda intacto y sigue acotando la tabla.
    html =
      render_change(view, "cambiar_override_valor", %{"valor" => %{clave_edad => ""}})
      |> then(fn _ -> render_change(view, "cambiar_override_valor_hasta", %{"valor_hasta" => %{clave_edad => ""}}) end)

    assert html =~ solo_nombre.meta_fixture_cliente_nombre
    assert html =~ otro.meta_fixture_cliente_nombre
  end

  # Bug real (2026-09-04, encontrado en producción con "Gastos"): "Suma"/
  # "Totalizado" sumaban TODAS las filas del catálogo, ignorando el
  # parámetro activo (ej. Fecha "Mes actual completo") — CatalogoGenerico.
  # agregar/6 no aplicaba `parametros` aunque listar/6 y contar/5 sí lo
  # hacían. Acá el parámetro es el nombre (texto), pero el mecanismo es
  # el mismo que un parámetro de Fecha.
  test "Totalizado suma solo las filas que matchean el parámetro activo, no la tabla entera", %{conn: conn} do
    header = MetaSchemaContext.obtener_header_por_nombre("meta_fixture_cliente")
    marcar_parametro(header, "meta_fixture_cliente_nombre")

    d_edad = detalle(header, "meta_fixture_cliente_edad")

    props_edad =
      Map.merge(d_edad.schema_context_properties, %{"agregacion_activa" => true, "total_general_activo" => true})

    {:ok, _} = MetaSchemaContext.actualizar_detalle(d_edad, %{"schema_context_properties" => props_edad})

    sufijo = unique()

    incluida =
      fixture_cliente(%{meta_fixture_cliente_nombre: "Elena Soto #{sufijo}", meta_fixture_cliente_edad: 10, meta_fixture_cliente_venta: Decimal.new("1")})

    fixture_cliente(%{meta_fixture_cliente_nombre: "Fabio Diaz #{sufijo}", meta_fixture_cliente_edad: 20, meta_fixture_cliente_venta: Decimal.new("1")})

    {:ok, view, _html} = live(conn, "/__test__/fixture-cliente")

    html = render_change(view, "cambiar_override_valor", %{"valor" => %{clave(header, "meta_fixture_cliente_nombre") => incluida.meta_fixture_cliente_nombre}})

    assert html =~ "Totalizado: 10"
    refute html =~ "Totalizado: 30"
  end
end
