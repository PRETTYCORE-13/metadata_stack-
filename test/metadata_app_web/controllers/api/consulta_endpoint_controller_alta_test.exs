defmodule MetadataAppWeb.Api.ConsultaEndpointControllerAltaTest do
  use MetadataAppWeb.ConnCase, async: true

  alias MetadataApp.Repo
  alias MetadataApp.MetaConsultas
  alias MetadataApp.ConsultaEndpoints
  alias MetadataApp.BusinessProcessBuilder.MetaSchemaContext
  alias MetadataApp.BusinessProcessBuilder.MetaSchema.Header
  alias MetadataApp.MetaSchema.Estado
  alias MetadataApp.MetaBusinessProcess.Catalogos.MetaFixtureCliente
  alias MetadataApp.Autenticacion.Empresa

  # R52-R58 (agregado 2026-09-14, a pedido explícito -- "necesito que
  # el post agregue registros") -- un endpoint con `permite_alta: true`
  # inserta un registro nuevo en su catálogo base en vez de consultar,
  # con las MISMAS reglas que un alta manual desde la UI (motor de
  # estados vía CatalogoGenerico.crear/4).

  defp guid, do: Ecto.UUID.generate() |> String.replace("-", "")
  defp unique, do: System.unique_integer([:positive])

  defp empresa! do
    {:ok, empresa} = %Empresa{} |> Empresa.changeset(%{nombre: "Empresa alta test #{unique()}"}) |> Repo.insert()
    empresa
  end

  defp header_clientes, do: Repo.get_by!(Header, schema_context_name: "meta_fixture_cliente")

  # meta_fixture_cliente no trae NINGÚN estado configurado por default
  # (catálogo fixture puro) -- CatalogoGenerico.crear/4 rechaza con
  # :motor_no_configurado a un catálogo de negocio con CERO estados
  # (decisión real de 2026-09-10, ver catalogo_generico.ex). Este
  # helper le da uno inicial, mismo patrón que ya usan otros tests de
  # este mismo catálogo (ver campos_editables_test.exs).
  defp fixture_estado_inicial! do
    %Estado{}
    |> Estado.changeset(%{meta_schema_header_id: header_clientes().id, orden: unique(), nombre: "inicial_#{unique()}", es_inicial: true})
    |> Ecto.Changeset.put_change(:insert_guid, guid())
    |> Repo.insert!()
  end

  defp endpoint_con_alta!(empresa, opts \\ []) do
    nombre = "consulta_endpoint_alta_#{unique()}"

    {:ok, {header, _}} =
      MetaSchemaContext.crear_header_con_detalles(%{
        "schema_context_name" => nombre,
        "schema_context_label" => "Consulta endpoint alta test",
        "schema_context_nav" => "/#{nombre}",
        "schema_visible" => true,
        "schema_context_type" => 3,
        "detalles" => []
      })

    {:ok, consulta} = MetaConsultas.crear(header, "meta_fixture_cliente")

    campos_alta =
      Keyword.get(opts, :campos_alta, ~w(meta_fixture_cliente_nombre meta_fixture_cliente_edad meta_fixture_cliente_venta))

    {:ok, endpoint} =
      ConsultaEndpoints.crear_o_actualizar(consulta, %{
        "nombre" => "Alta de clientes",
        "metodo" => "post",
        "ruta" => Keyword.get(opts, :ruta, "clientes-alta-#{unique()}"),
        "empresa_id" => empresa.id,
        "parametros" => [],
        "permite_alta" => true,
        "campos_alta" => campos_alta
      })

    {:ok, publicado} = ConsultaEndpoints.publicar(endpoint)
    {:ok, _credencial, key} = ConsultaEndpoints.crear_credencial(publicado, consulta, %{"nombre" => "Test", "campos_permitidos" => []})

    {publicado, key}
  end

  test "POST con permite_alta inserta un registro real, mismas reglas que un alta manual (motor de estados)", %{conn: conn} do
    fixture_estado_inicial!()
    empresa = empresa!()
    {endpoint, key} = endpoint_con_alta!(empresa)

    nombre = "cliente alta #{unique()}"

    conn =
      conn
      |> put_req_header("authorization", "Bearer #{key}")
      |> post("/api/consultas/#{endpoint.ruta}", %{
        "meta_fixture_cliente_nombre" => nombre,
        "meta_fixture_cliente_edad" => 42,
        "meta_fixture_cliente_venta" => "99.90"
      })

    body = json_response(conn, 201)
    assert %{"data" => %{"id" => id}} = body

    registro = Repo.get!(MetaFixtureCliente, id)
    assert registro.meta_fixture_cliente_nombre == nombre
    assert registro.meta_fixture_cliente_edad == 42
    assert Decimal.equal?(registro.meta_fixture_cliente_venta, Decimal.new("99.90"))
    # Mismas reglas que un alta manual (R52) -- nace en el estado inicial.
    assert registro.estado_id
  end

  test "empresa_id siempre es la del endpoint, nunca la que mande el caller (R55)", %{conn: conn} do
    fixture_estado_inicial!()
    empresa = empresa!()
    otra_empresa = empresa!()
    {endpoint, key} = endpoint_con_alta!(empresa)

    conn =
      conn
      |> put_req_header("authorization", "Bearer #{key}")
      |> post("/api/consultas/#{endpoint.ruta}", %{
        "meta_fixture_cliente_nombre" => "cliente #{unique()}",
        "meta_fixture_cliente_edad" => 20,
        "meta_fixture_cliente_venta" => "1.00",
        "empresa_id" => otra_empresa.id
      })

    %{"data" => %{"id" => id}} = json_response(conn, 201)
    registro = Repo.get!(MetaFixtureCliente, id)
    assert registro.empresa_id == empresa.id
    refute registro.empresa_id == otra_empresa.id
  end

  test "un campo real que el admin NO habilitó en campos_alta se ignora aunque el caller lo mande (R54)", %{conn: conn} do
    fixture_estado_inicial!()
    empresa = empresa!()

    {endpoint, key} =
      endpoint_con_alta!(empresa, campos_alta: ~w(meta_fixture_cliente_nombre meta_fixture_cliente_edad meta_fixture_cliente_venta))

    conn =
      conn
      |> put_req_header("authorization", "Bearer #{key}")
      |> post("/api/consultas/#{endpoint.ruta}", %{
        "meta_fixture_cliente_nombre" => "cliente #{unique()}",
        "meta_fixture_cliente_edad" => 20,
        "meta_fixture_cliente_venta" => "1.00",
        "meta_fixture_cliente_sucursal_id" => 987_654
      })

    %{"data" => %{"id" => id}} = json_response(conn, 201)
    registro = Repo.get!(MetaFixtureCliente, id)
    refute registro.meta_fixture_cliente_sucursal_id == 987_654
  end

  test "body sin ninguna coincidencia con campos_alta -> 422 explícito, no inserta una fila vacía (R65)", %{conn: conn} do
    fixture_estado_inicial!()
    empresa = empresa!()
    {endpoint, key} = endpoint_con_alta!(empresa)

    total_antes = Repo.aggregate(MetaFixtureCliente, :count)

    conn =
      conn
      |> put_req_header("authorization", "Bearer #{key}")
      |> post("/api/consultas/#{endpoint.ruta}", %{})

    assert %{"error" => mensaje} = json_response(conn, 422)
    assert mensaje =~ "no coincide con ningún campo"
    assert Repo.aggregate(MetaFixtureCliente, :count) == total_antes
  end

  test "falta un campo obligatorio del catálogo -> 422, no inserta nada", %{conn: conn} do
    fixture_estado_inicial!()
    empresa = empresa!()
    {endpoint, key} = endpoint_con_alta!(empresa)

    conn =
      conn
      |> put_req_header("authorization", "Bearer #{key}")
      |> post("/api/consultas/#{endpoint.ruta}", %{"meta_fixture_cliente_edad" => 20, "meta_fixture_cliente_venta" => "1.00"})

    assert %{"error" => mensaje} = json_response(conn, 422)
    assert mensaje =~ "nombre"
  end

  test "catálogo sin motor de estados configurado -> 422 con el error real, no un insert silencioso", %{conn: conn} do
    empresa = empresa!()
    {endpoint, key} = endpoint_con_alta!(empresa)

    conn =
      conn
      |> put_req_header("authorization", "Bearer #{key}")
      |> post("/api/consultas/#{endpoint.ruta}", %{
        "meta_fixture_cliente_nombre" => "cliente #{unique()}",
        "meta_fixture_cliente_edad" => 20,
        "meta_fixture_cliente_venta" => "1.00"
      })

    assert %{"error" => _mensaje} = json_response(conn, 422)
  end
end
