defmodule MetadataAppWeb.Api.ConsultaEndpointControllerServicioTest do
  @moduledoc "SPEC-SYS-2509202601 O3: Endpoint sobre un Servicio (R49-R51)."
  use MetadataAppWeb.ConnCase, async: true

  import Ecto.Query

  alias MetadataApp.Repo
  alias MetadataApp.ConsultasSql
  alias MetadataApp.ConsultaEndpoints
  alias MetadataApp.MetaSchema.ConsultaEndpointLog
  alias MetadataApp.Autenticacion.Empresa

  defp unique, do: System.unique_integer([:positive])

  defp empresa! do
    {:ok, empresa} =
      %Empresa{}
      |> Empresa.changeset(%{nombre: "Empresa servicio http #{unique()}"})
      |> Repo.insert()

    empresa
  end

  # Filas 1 y 2 sin empresa (visibles para cualquiera); la 3 de otra empresa.
  @sql_datos "SELECT t.id, t.nombre, t.empresa_id FROM (VALUES (1, 'uno', NULL::bigint), (2, 'dos', NULL), (3, 'otra', -1)) AS t(id, nombre, empresa_id) WHERE t.id = ANY(:ids)"

  defp servicio!(sql \\ @sql_datos, parametros \\ nil, tope \\ 1000) do
    {:ok, {header, _}} =
      ConsultasSql.crear(%{
        "etiqueta" => "Svc http",
        "nav" => "/svc_http_#{unique()}",
        "uso" => "servicio"
      })

    parametros =
      parametros || [%{"nombre" => "ids", "tipo" => "lista_enteros", "obligatorio" => true}]

    {:ok, servicio} =
      ConsultasSql.guardar_sql(header.schema_context_name, sql, %{
        "parametros" => parametros,
        "tope_renglones" => tope
      })

    servicio
  end

  defp endpoint!(servicio, opts \\ []) do
    empresa = empresa!()
    ruta = "svc-http-#{unique()}"

    {:ok, endpoint} =
      ConsultaEndpoints.crear_o_actualizar(servicio, %{
        "nombre" => "Servicio http",
        "metodo" => Keyword.get(opts, :metodo, "get"),
        "ruta" => ruta,
        "empresa_id" => empresa.id
      })

    {:ok, endpoint} = ConsultaEndpoints.publicar(endpoint)

    permitidos =
      Keyword.get(opts, :campos_permitidos, Enum.map(servicio.columnas, & &1["nombre"]))

    {:ok, _credencial, key} =
      ConsultaEndpoints.crear_credencial(endpoint, servicio, %{
        "nombre" => "App",
        "campos_permitidos" => permitidos
      })

    %{endpoint: endpoint, ruta: ruta, key: key}
  end

  defp con_key(conn, key), do: put_req_header(conn, "authorization", "Bearer #{key}")

  defp ids(body), do: body["data"] |> Enum.map(& &1["id"]) |> Enum.sort()

  test "GET con lista 1,2,3: regresa las filas y acota por la empresa del endpoint", %{conn: conn} do
    %{ruta: ruta, key: key} = endpoint!(servicio!())
    body = conn |> con_key(key) |> get("/api/consultas/#{ruta}?ids=1,2,3") |> json_response(200)

    assert ids(body) == [1, 2]
    assert body["meta_campos"] == ["id", "nombre", "empresa_id"]
    refute Map.has_key?(body, "meta") and Map.has_key?(body["meta"] || %{}, "pagina")
  end

  test "GET con x[]=1&x[]=2", %{conn: conn} do
    %{ruta: ruta, key: key} = endpoint!(servicio!())

    body =
      conn |> con_key(key) |> get("/api/consultas/#{ruta}?ids[]=1&ids[]=2") |> json_response(200)

    assert ids(body) == [1, 2]
  end

  test "R50: POST con JSON aunque el endpoint se configuró como GET", %{conn: conn} do
    %{endpoint: endpoint, ruta: ruta, key: key} = endpoint!(servicio!(), metodo: "get")

    body =
      conn
      |> con_key(key)
      |> put_req_header("content-type", "application/json")
      |> post("/api/consultas/#{ruta}", Jason.encode!(%{"ids" => [2]}))
      |> json_response(200)

    assert ids(body) == [2]

    # La auditoría registra el método de la petición, no el configurado.
    assert ["post"] =
             Repo.all(
               from(l in ConsultaEndpointLog,
                 where: l.meta_schema_consulta_endpoint_id == ^endpoint.id,
                 select: l.metodo
               )
             )
  end

  test "R44/R43 de Endpoints: la credencial recorta las columnas", %{conn: conn} do
    %{ruta: ruta, key: key} = endpoint!(servicio!(), campos_permitidos: ["id"])
    body = conn |> con_key(key) |> get("/api/consultas/#{ruta}?ids=1") |> json_response(200)
    assert body["data"] == [%{"id" => 1}]
    assert body["meta_campos"] == ["id"]
  end

  test "parámetro faltante o inválido: 400 que nombra el parámetro", %{conn: conn} do
    %{ruta: ruta, key: key} = endpoint!(servicio!())

    assert conn |> con_key(key) |> get("/api/consultas/#{ruta}") |> json_response(400) ==
             %{"error" => "Falta el parámetro obligatorio «ids»."}

    assert %{"error" => mensaje} =
             build_conn()
             |> con_key(key)
             |> get("/api/consultas/#{ruta}?ids=1,x")
             |> json_response(400)

    assert mensaje =~ "«ids» no es un valor válido"
  end

  test "sin key o con key inválida: 401", %{conn: conn} do
    %{ruta: ruta} = endpoint!(servicio!())
    assert conn |> get("/api/consultas/#{ruta}?ids=1") |> json_response(401)

    assert build_conn()
           |> con_key("no-es-la-key")
           |> get("/api/consultas/#{ruta}?ids=1")
           |> json_response(401)
  end

  test "resultado mayor al tope: 422", %{conn: conn} do
    %{ruta: ruta, key: key} = endpoint!(servicio!(@sql_datos, nil, 1))

    assert %{"error" => mensaje} =
             conn |> con_key(key) |> get("/api/consultas/#{ruta}?ids=1,2") |> json_response(422)

    assert mensaje =~ "excede el tope de 1 renglones"
  end

  test "error de ejecución del SQL: 500 genérico, sin detalles de la base", %{conn: conn} do
    servicio =
      servicio!("SELECT 1 / :d AS r", [
        %{"nombre" => "d", "tipo" => "entero", "obligatorio" => true}
      ])

    %{ruta: ruta, key: key} = endpoint!(servicio)

    assert conn |> con_key(key) |> get("/api/consultas/#{ruta}?d=0") |> json_response(500) ==
             %{"error" => "No se pudo ejecutar el servicio"}
  end

  test "cada llamada queda en la auditoría", %{conn: conn} do
    %{endpoint: endpoint, ruta: ruta, key: key} = endpoint!(servicio!())
    conn |> con_key(key) |> get("/api/consultas/#{ruta}?ids=1") |> json_response(200)

    assert [%{resultado_http: 200, cantidad_registros: 1}] =
             Repo.all(
               from(l in ConsultaEndpointLog,
                 where: l.meta_schema_consulta_endpoint_id == ^endpoint.id
               )
             )
  end

  test "si el Servicio cambia sus parámetros, el endpoint los toma", %{conn: conn} do
    servicio = servicio!()
    %{endpoint: endpoint, ruta: ruta, key: key} = endpoint!(servicio)
    nombre = Repo.preload(servicio, :header).header.schema_context_name

    {:ok, _} =
      ConsultasSql.guardar_sql(
        nombre,
        "SELECT :n AS id, 'x' AS nombre, NULL::bigint AS empresa_id",
        %{
          "parametros" => [%{"nombre" => "n", "tipo" => "entero", "obligatorio" => true}]
        }
      )

    assert [%{"nombre" => "n"}] = Repo.reload(endpoint).parametros
    body = conn |> con_key(key) |> get("/api/consultas/#{ruta}?n=7") |> json_response(200)
    assert ids(body) == [7]
  end
end
