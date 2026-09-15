defmodule MetadataAppWeb.Api.ConsultaEndpointJobControllerTest do
  use MetadataAppWeb.ConnCase, async: true

  alias MetadataApp.Repo
  alias MetadataApp.MetaConsultas
  alias MetadataApp.ConsultaEndpoints
  alias MetadataApp.BusinessProcessBuilder.MetaSchemaContext
  alias MetadataApp.MetaBusinessProcess.Catalogos.MetaFixtureCliente
  alias MetadataApp.Autenticacion.Empresa

  defp guid, do: Ecto.UUID.generate() |> String.replace("-", "")
  defp unique, do: System.unique_integer([:positive])

  defp empresa! do
    {:ok, empresa} = %Empresa{} |> Empresa.changeset(%{nombre: "Empresa job test #{unique()}"}) |> Repo.insert()
    empresa
  end

  defp fixture_cliente(attrs) do
    %MetaFixtureCliente{}
    |> MetaFixtureCliente.changeset(
      Map.merge(
        %{meta_fixture_cliente_nombre: "job endpoint #{unique()}", meta_fixture_cliente_edad: 30, meta_fixture_cliente_venta: Decimal.new("100.00")},
        attrs
      )
    )
    |> Ecto.Changeset.put_change(:insert_guid, guid())
    |> Repo.insert!()
  end

  defp clave_nombre, do: "meta_fixture_cliente__meta_fixture_cliente_nombre"

  defp consulta_con_parametro! do
    nombre = "consulta_job_http_#{unique()}"

    {:ok, {header, _}} =
      MetaSchemaContext.crear_header_con_detalles(%{
        "schema_context_name" => nombre,
        "schema_context_label" => "Consulta job http test",
        "schema_context_nav" => "/#{nombre}",
        "schema_visible" => true,
        "schema_context_type" => 3,
        "detalles" => []
      })

    {:ok, consulta} = MetaConsultas.crear(header, "meta_fixture_cliente")

    campos =
      Enum.map(consulta.campos, fn campo ->
        if campo["campo"] == "meta_fixture_cliente_nombre" do
          Map.merge(campo, %{"tipo" => "string", "es_parametro" => true})
        else
          campo
        end
      end)

    {:ok, consulta} = MetaConsultas.actualizar_campos(consulta, campos)
    consulta
  end

  defp claves_visibles(consulta) do
    consulta.campos
    |> Enum.filter(&(&1["visible"] == true))
    |> Enum.map(&(&1 |> MetaConsultas.clave_campo() |> to_string()))
  end

  defp endpoint_publicado!(consulta, empresa) do
    {:ok, endpoint} =
      ConsultaEndpoints.crear_o_actualizar(consulta, %{
        "nombre" => "Clientes",
        "metodo" => "get",
        "ruta" => "clientes-job-#{unique()}",
        "empresa_id" => empresa.id,
        "parametros" => [%{"campo" => clave_nombre(), "obligatorio" => false}]
      })

    {:ok, publicado} = ConsultaEndpoints.publicar(endpoint)

    {:ok, _credencial, key} =
      ConsultaEndpoints.crear_credencial(publicado, consulta, %{"nombre" => "Test", "campos_permitidos" => claves_visibles(consulta)})

    {publicado, key}
  end

  test "encolar, esperar a completado (Oban :inline) y descargar el NDJSON con las filas esperadas", %{conn: conn} do
    empresa = empresa!()
    consulta = consulta_con_parametro!()
    prefijo = "job_#{unique()}"

    for n <- 1..3, do: fixture_cliente(%{empresa_id: empresa.id, meta_fixture_cliente_nombre: "#{prefijo}-#{n}"})

    {endpoint, key} = endpoint_publicado!(consulta, empresa)

    conn_crear =
      conn
      |> put_req_header("authorization", "Bearer #{key}")
      |> post("/api/consultas/#{endpoint.ruta}/jobs?#{MetaConsultas.clave_campo(%{"catalogo" => "meta_fixture_cliente", "campo" => "meta_fixture_cliente_nombre"}) |> to_string()}=#{prefijo}")

    body_creado = json_response(conn_crear, 202)
    assert body_creado["estado"] == "completado"
    job_id = body_creado["job_id"]

    conn_mostrar =
      build_conn()
      |> put_req_header("authorization", "Bearer #{key}")
      |> get("/api/consultas/#{endpoint.ruta}/jobs/#{job_id}")

    assert conn_mostrar.status == 200
    assert get_resp_header(conn_mostrar, "content-type") |> List.first() =~ "application/x-ndjson"

    lineas = conn_mostrar.resp_body |> String.split("\n", trim: true)
    assert length(lineas) == 3

    nombres =
      lineas
      |> Enum.map(&Jason.decode!/1)
      |> Enum.map(& &1["meta_fixture_cliente__meta_fixture_cliente_nombre"])

    assert Enum.sort(nombres) == Enum.sort(for n <- 1..3, do: "#{prefijo}-#{n}")
  end

  test "sin Authorization -> 401, no encola nada", %{conn: conn} do
    empresa = empresa!()
    consulta = consulta_con_parametro!()
    {endpoint, _key} = endpoint_publicado!(consulta, empresa)

    conn = post(conn, "/api/consultas/#{endpoint.ruta}/jobs")
    assert json_response(conn, 401)
  end

  test "job de otro endpoint -> 404, aunque la credencial sea válida para el propio", %{conn: conn} do
    empresa = empresa!()
    consulta_a = consulta_con_parametro!()
    consulta_b = consulta_con_parametro!()
    {endpoint_a, key_a} = endpoint_publicado!(consulta_a, empresa)
    {endpoint_b, key_b} = endpoint_publicado!(consulta_b, empresa)

    conn_crear =
      conn |> put_req_header("authorization", "Bearer #{key_a}") |> post("/api/consultas/#{endpoint_a.ruta}/jobs")

    job_id = json_response(conn_crear, 202)["job_id"]

    conn_ajeno =
      build_conn()
      |> put_req_header("authorization", "Bearer #{key_b}")
      |> get("/api/consultas/#{endpoint_b.ruta}/jobs/#{job_id}")

    assert json_response(conn_ajeno, 404)
  end
end
