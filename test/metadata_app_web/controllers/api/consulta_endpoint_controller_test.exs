defmodule MetadataAppWeb.Api.ConsultaEndpointControllerTest do
  use MetadataAppWeb.ConnCase, async: true

  import Ecto.Query

  alias MetadataApp.Repo
  alias MetadataApp.MetaConsultas
  alias MetadataApp.ConsultaEndpoints
  alias MetadataApp.BusinessProcessBuilder.MetaSchemaContext
  alias MetadataApp.MetaBusinessProcess.Catalogos.MetaFixtureCliente
  alias MetadataApp.MetaSchema.ConsultaEndpointLog
  alias MetadataApp.Autenticacion.Empresa

  defp guid, do: Ecto.UUID.generate() |> String.replace("-", "")
  defp unique, do: System.unique_integer([:positive])

  defp empresa! do
    {:ok, empresa} = %Empresa{} |> Empresa.changeset(%{nombre: "Empresa controller test #{unique()}"}) |> Repo.insert()
    empresa
  end

  defp fixture_cliente(attrs) do
    %MetaFixtureCliente{}
    |> MetaFixtureCliente.changeset(
      Map.merge(
        %{meta_fixture_cliente_nombre: "http endpoint #{unique()}", meta_fixture_cliente_edad: 30, meta_fixture_cliente_venta: Decimal.new("100.00")},
        attrs
      )
    )
    |> Ecto.Changeset.put_change(:insert_guid, guid())
    |> Repo.insert!()
  end

  defp consulta_con_parametro! do
    nombre = "consulta_endpoint_http_#{unique()}"

    {:ok, {header, _}} =
      MetaSchemaContext.crear_header_con_detalles(%{
        "schema_context_name" => nombre,
        "schema_context_label" => "Consulta endpoint http test",
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

  defp clave_nombre, do: "meta_fixture_cliente__meta_fixture_cliente_nombre"

  defp claves_visibles(consulta) do
    consulta.campos
    |> Enum.filter(&(&1["visible"] == true))
    |> Enum.map(&(&1 |> MetaConsultas.clave_campo() |> to_string()))
  end

  # Publica el endpoint y le crea UNA credencial con TODOS los campos
  # visibles permitidos (R42) -- así los tests que ya afirman sobre la
  # forma completa de "data" (previos a R19.1) no necesitan cambiar.
  defp endpoint_publicado!(consulta, empresa, opts \\ []) do
    ruta = Keyword.get(opts, :ruta, "clientes-#{unique()}")
    metodo = Keyword.get(opts, :metodo, "get")
    parametros = Keyword.get(opts, :parametros, [%{"campo" => clave_nombre(), "obligatorio" => false}])
    campos_permitidos = Keyword.get(opts, :campos_permitidos, claves_visibles(consulta))

    {:ok, endpoint} =
      ConsultaEndpoints.crear_o_actualizar(consulta, %{
        "nombre" => "Clientes",
        "metodo" => metodo,
        "ruta" => ruta,
        "empresa_id" => empresa.id,
        "parametros" => parametros
      })

    {:ok, publicado} = ConsultaEndpoints.publicar(endpoint)

    {:ok, _credencial, key} =
      ConsultaEndpoints.crear_credencial(publicado, consulta, %{"nombre" => "Test", "campos_permitidos" => campos_permitidos})

    {publicado, key}
  end

  describe "autenticación (D2)" do
    test "sin Authorization -> 401, no ejecuta nada", %{conn: conn} do
      empresa = empresa!()
      consulta = consulta_con_parametro!()
      {endpoint, _key} = endpoint_publicado!(consulta, empresa)

      conn = get(conn, "/api/consultas/#{endpoint.ruta}")

      assert json_response(conn, 401)["error"]
    end

    test "key incorrecta -> 401", %{conn: conn} do
      empresa = empresa!()
      consulta = consulta_con_parametro!()
      {endpoint, _key} = endpoint_publicado!(consulta, empresa)

      conn = conn |> put_req_header("authorization", "Bearer key-incorrecta") |> get("/api/consultas/#{endpoint.ruta}")

      assert json_response(conn, 401)["error"]
    end

    test "endpoint en borrador -> 404 aunque la key sea la correcta", %{conn: conn} do
      empresa = empresa!()
      consulta = consulta_con_parametro!()
      {endpoint, key} = endpoint_publicado!(consulta, empresa)
      {:ok, despublicado} = ConsultaEndpoints.despublicar(endpoint)

      conn = conn |> put_req_header("authorization", "Bearer #{key}") |> get("/api/consultas/#{despublicado.ruta}")

      assert json_response(conn, 404)["error"]
    end

    test "ruta inexistente -> 404", %{conn: conn} do
      conn = get(conn, "/api/consultas/no-existe-#{unique()}")
      assert json_response(conn, 404)["error"]
    end
  end

  describe "parámetros (D3)" do
    test "falta un parámetro obligatorio -> 400 con el nombre", %{conn: conn} do
      empresa = empresa!()
      consulta = consulta_con_parametro!()
      {endpoint, key} = endpoint_publicado!(consulta, empresa, parametros: [%{"campo" => clave_nombre(), "obligatorio" => true}])

      conn = conn |> put_req_header("authorization", "Bearer #{key}") |> get("/api/consultas/#{endpoint.ruta}")

      assert %{"error" => mensaje} = json_response(conn, 400)
      assert mensaje =~ clave_nombre()
    end

    test "un empresa_id en query string nunca cambia la empresa (R13)", %{conn: conn} do
      empresa_endpoint = empresa!()
      otra_empresa = empresa!()
      consulta = consulta_con_parametro!()
      {endpoint, key} = endpoint_publicado!(consulta, empresa_endpoint)

      fixture_cliente(%{empresa_id: empresa_endpoint.id, meta_fixture_cliente_nombre: "propio_#{unique()}"})
      fixture_cliente(%{empresa_id: otra_empresa.id, meta_fixture_cliente_nombre: "ajeno_#{unique()}"})

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{key}")
        |> get("/api/consultas/#{endpoint.ruta}?empresa_id=#{otra_empresa.id}")

      body = json_response(conn, 200)
      nombres = Enum.map(body["data"], & &1["meta_fixture_cliente__meta_fixture_cliente_nombre"])

      refute Enum.any?(nombres, &String.starts_with?(&1, "ajeno_"))
    end
  end

  describe "paginación (D4)" do
    test "por_pagina por encima del tope se recorta, nunca se rechaza", %{conn: conn} do
      empresa = empresa!()
      consulta = consulta_con_parametro!()
      {endpoint, key} = endpoint_publicado!(consulta, empresa)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{key}")
        |> get("/api/consultas/#{endpoint.ruta}?por_pagina=999999")

      assert %{"meta" => %{"por_pagina" => 200}} = json_response(conn, 200)
    end

    test "pagina/por_pagina inválidos caen a los defaults en vez de crashear", %{conn: conn} do
      empresa = empresa!()
      consulta = consulta_con_parametro!()
      {endpoint, key} = endpoint_publicado!(consulta, empresa)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{key}")
        |> get("/api/consultas/#{endpoint.ruta}?pagina=abc&por_pagina=-5")

      assert %{"meta" => %{"pagina" => 1, "por_pagina" => 1}} = json_response(conn, 200)
    end
  end

  describe "respuesta y alcance por empresa (D5)" do
    test "GET por query string y POST por body dan el mismo resultado para el mismo valor", %{conn: conn} do
      empresa = empresa!()
      consulta = consulta_con_parametro!()
      nombre_buscado = "buscado_#{unique()}"
      fixture_cliente(%{empresa_id: empresa.id, meta_fixture_cliente_nombre: nombre_buscado})

      {endpoint_get, key} = endpoint_publicado!(consulta, empresa, metodo: "get", ruta: "clientes-get-#{unique()}")

      conn_get =
        conn
        |> put_req_header("authorization", "Bearer #{key}")
        |> get("/api/consultas/#{endpoint_get.ruta}?#{clave_nombre()}=#{nombre_buscado}")

      body_get = json_response(conn_get, 200)
      assert [%{"meta_fixture_cliente__meta_fixture_cliente_nombre" => ^nombre_buscado}] = body_get["data"]

      nombre_buscado_post = "buscado_#{unique()}"
      consulta_post = consulta_con_parametro!()
      fixture_cliente(%{empresa_id: empresa.id, meta_fixture_cliente_nombre: nombre_buscado_post})
      {endpoint_post, key_post} = endpoint_publicado!(consulta_post, empresa, metodo: "post", ruta: "clientes-post-#{unique()}")

      conn_post =
        build_conn()
        |> put_req_header("authorization", "Bearer #{key_post}")
        |> post("/api/consultas/#{endpoint_post.ruta}", %{clave_nombre() => nombre_buscado_post})

      body_post = json_response(conn_post, 200)
      assert [%{"meta_fixture_cliente__meta_fixture_cliente_nombre" => ^nombre_buscado_post}] = body_post["data"]
    end

    test "solo devuelve filas de la empresa del endpoint, aunque existan de otra empresa en la misma tabla", %{conn: conn} do
      empresa_a = empresa!()
      empresa_b = empresa!()
      consulta = consulta_con_parametro!()
      prefijo = "alcance_#{unique()}"

      fixture_cliente(%{empresa_id: empresa_a.id, meta_fixture_cliente_nombre: "#{prefijo}-a"})
      fixture_cliente(%{empresa_id: empresa_b.id, meta_fixture_cliente_nombre: "#{prefijo}-b"})

      {endpoint, key} = endpoint_publicado!(consulta, empresa_a)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{key}")
        |> get("/api/consultas/#{endpoint.ruta}?#{clave_nombre()}=#{prefijo}")

      body = json_response(conn, 200)
      nombres = Enum.map(body["data"], & &1["meta_fixture_cliente__meta_fixture_cliente_nombre"])

      assert "#{prefijo}-a" in nombres
      refute "#{prefijo}-b" in nombres
    end
  end

  describe "credenciales -- alcance por campo (G5, R43-R44)" do
    test "dos credenciales del mismo endpoint solo ven sus propios campos_permitidos", %{conn: conn} do
      empresa = empresa!()
      consulta = consulta_con_parametro!()
      nombre_buscado = "campos_#{unique()}"
      fixture_cliente(%{empresa_id: empresa.id, meta_fixture_cliente_nombre: nombre_buscado, meta_fixture_cliente_edad: 42})

      clave_edad = "meta_fixture_cliente__meta_fixture_cliente_edad"

      {endpoint, key_solo_nombre} =
        endpoint_publicado!(consulta, empresa, campos_permitidos: [clave_nombre()])

      [_credencial_nombre] = ConsultaEndpoints.listar_credenciales(endpoint.id)

      {:ok, _credencial_edad, key_solo_edad} =
        ConsultaEndpoints.crear_credencial(endpoint, consulta, %{
          "nombre" => "Solo edad",
          "campos_permitidos" => [clave_edad]
        })

      conn_nombre =
        conn
        |> put_req_header("authorization", "Bearer #{key_solo_nombre}")
        |> get("/api/consultas/#{endpoint.ruta}?#{clave_nombre()}=#{nombre_buscado}")

      [fila_nombre] = json_response(conn_nombre, 200)["data"]
      assert fila_nombre == %{clave_nombre() => nombre_buscado}

      conn_edad =
        build_conn()
        |> put_req_header("authorization", "Bearer #{key_solo_edad}")
        |> get("/api/consultas/#{endpoint.ruta}?#{clave_nombre()}=#{nombre_buscado}")

      [fila_edad] = json_response(conn_edad, 200)["data"]
      assert fila_edad == %{clave_edad => 42}
    end
  end

  describe "paginación por cursor (H3, R35-R38)" do
    test "sin ?cursor, sigue el camino de pagina/por_pagina de siempre (R37)", %{conn: conn} do
      empresa = empresa!()
      consulta = consulta_con_parametro!()
      {endpoint, key} = endpoint_publicado!(consulta, empresa)

      conn = conn |> put_req_header("authorization", "Bearer #{key}") |> get("/api/consultas/#{endpoint.ruta}")

      assert %{"meta" => %{"pagina" => 1, "por_pagina" => 50, "total" => _}} = json_response(conn, 200)
    end

    test "con ?cursor=, pagina de punta a punta sin duplicados ni huecos, sin \"total\" en meta", %{conn: conn} do
      empresa = empresa!()
      consulta = consulta_con_parametro!()
      prefijo = "cursor_http_#{unique()}"
      for n <- 1..5, do: fixture_cliente(%{empresa_id: empresa.id, meta_fixture_cliente_nombre: "#{prefijo}-#{n}"})

      {endpoint, key} = endpoint_publicado!(consulta, empresa)

      conn_p1 =
        conn
        |> put_req_header("authorization", "Bearer #{key}")
        |> get("/api/consultas/#{endpoint.ruta}?#{clave_nombre()}=#{prefijo}&cursor=&limite=2")

      body_p1 = json_response(conn_p1, 200)
      assert length(body_p1["data"]) == 2
      assert body_p1["meta"]["tiene_mas"] == true
      refute Map.has_key?(body_p1["meta"], "total")
      cursor2 = body_p1["meta"]["cursor_siguiente"]
      refute is_nil(cursor2)

      conn_p2 =
        build_conn()
        |> put_req_header("authorization", "Bearer #{key}")
        |> get("/api/consultas/#{endpoint.ruta}?#{clave_nombre()}=#{prefijo}&cursor=#{cursor2}&limite=2")

      body_p2 = json_response(conn_p2, 200)
      assert length(body_p2["data"]) == 2
      cursor3 = body_p2["meta"]["cursor_siguiente"]

      conn_p3 =
        build_conn()
        |> put_req_header("authorization", "Bearer #{key}")
        |> get("/api/consultas/#{endpoint.ruta}?#{clave_nombre()}=#{prefijo}&cursor=#{cursor3}&limite=2")

      body_p3 = json_response(conn_p3, 200)
      assert length(body_p3["data"]) == 1
      assert body_p3["meta"]["tiene_mas"] == false
      assert is_nil(body_p3["meta"]["cursor_siguiente"])

      nombres =
        (body_p1["data"] ++ body_p2["data"] ++ body_p3["data"])
        |> Enum.map(& &1["meta_fixture_cliente__meta_fixture_cliente_nombre"])

      assert Enum.sort(nombres) == Enum.sort(for n <- 1..5, do: "#{prefijo}-#{n}")
    end

    test "un cursor mal formado -> 400, sin ejecutar nada", %{conn: conn} do
      empresa = empresa!()
      consulta = consulta_con_parametro!()
      {endpoint, key} = endpoint_publicado!(consulta, empresa)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{key}")
        |> get("/api/consultas/#{endpoint.ruta}?cursor=no-es-base64-valido!!")

      assert json_response(conn, 400)["error"]
    end
  end

  describe "auditoría (D6, F3)" do
    test "una llamada exitosa y una con 401 dejan cada una su fila, sin key ni valores", %{conn: conn} do
      empresa = empresa!()
      consulta = consulta_con_parametro!()
      {endpoint, key} = endpoint_publicado!(consulta, empresa)

      conn
      |> put_req_header("authorization", "Bearer #{key}")
      |> get("/api/consultas/#{endpoint.ruta}")

      build_conn()
      |> put_req_header("authorization", "Bearer key-mala")
      |> get("/api/consultas/#{endpoint.ruta}")

      logs =
        Repo.all(from(l in ConsultaEndpointLog, where: l.meta_schema_consulta_endpoint_id == ^endpoint.id, order_by: l.id))

      assert length(logs) == 2
      assert Enum.map(logs, & &1.resultado_http) |> Enum.sort() == [200, 401]
      assert Enum.all?(logs, &(&1.empresa_id == empresa.id))

      for log <- logs do
        refute Map.has_key?(Map.from_struct(log), :api_key)
        refute Map.has_key?(Map.from_struct(log), :valores)
      end
    end
  end

  describe "verificación end-to-end (Grupo F)" do
    test "F1 -- pagina de punta a punta entre 2 páginas reales con Bearer válido", %{conn: conn} do
      empresa = empresa!()
      consulta = consulta_con_parametro!()
      prefijo = "pag_#{unique()}"

      for n <- 1..3, do: fixture_cliente(%{empresa_id: empresa.id, meta_fixture_cliente_nombre: "#{prefijo}-#{n}"})

      {endpoint, key} =
        endpoint_publicado!(consulta, empresa, parametros: [%{"campo" => clave_nombre(), "obligatorio" => false}])

      conn_p1 =
        conn
        |> put_req_header("authorization", "Bearer #{key}")
        |> get("/api/consultas/#{endpoint.ruta}?#{clave_nombre()}=#{prefijo}&pagina=1&por_pagina=2")

      body_p1 = json_response(conn_p1, 200)
      assert length(body_p1["data"]) == 2
      assert %{"pagina" => 1, "por_pagina" => 2, "total" => 3, "total_paginas" => 2} = body_p1["meta"]

      conn_p2 =
        build_conn()
        |> put_req_header("authorization", "Bearer #{key}")
        |> get("/api/consultas/#{endpoint.ruta}?#{clave_nombre()}=#{prefijo}&pagina=2&por_pagina=2")

      body_p2 = json_response(conn_p2, 200)
      assert length(body_p2["data"]) == 1
      assert %{"pagina" => 2, "total" => 3, "total_paginas" => 2} = body_p2["meta"]

      nombres_p1 = Enum.map(body_p1["data"], & &1["meta_fixture_cliente__meta_fixture_cliente_nombre"])
      nombres_p2 = Enum.map(body_p2["data"], & &1["meta_fixture_cliente__meta_fixture_cliente_nombre"])
      assert MapSet.disjoint?(MapSet.new(nombres_p1), MapSet.new(nombres_p2))
    end

    test "F2 -- regenerar invalida la key anterior de inmediato, a nivel HTTP", %{conn: conn} do
      empresa = empresa!()
      consulta = consulta_con_parametro!()
      {endpoint, key_vieja} = endpoint_publicado!(consulta, empresa)
      [credencial] = ConsultaEndpoints.listar_credenciales(endpoint.id)

      {:ok, _regenerada, key_nueva} = ConsultaEndpoints.regenerar_api_key_credencial(credencial)

      conn_vieja = conn |> put_req_header("authorization", "Bearer #{key_vieja}") |> get("/api/consultas/#{endpoint.ruta}")
      assert json_response(conn_vieja, 401)

      conn_nueva =
        build_conn() |> put_req_header("authorization", "Bearer #{key_nueva}") |> get("/api/consultas/#{endpoint.ruta}")

      assert json_response(conn_nueva, 200)
    end
  end
end
