defmodule MetadataAppWeb.BusinessProcessBuilder.ConsultaControllerTest do
  use MetadataAppWeb.ConnCase, async: true

  alias MetadataApp.BusinessProcessBuilder.MetaSchemaContext
  alias MetadataApp.MetaConsultas
  alias MetadataApp.MetaBusinessProcess.Catalogos.MetaFixtureCliente
  alias MetadataApp.Repo

  defp guid, do: Ecto.UUID.generate() |> String.replace("-", "")
  defp unique, do: System.unique_integer([:positive])

  defp fixture_cliente(attrs) do
    %MetaFixtureCliente{}
    |> MetaFixtureCliente.changeset(
      Map.merge(
        %{meta_fixture_cliente_nombre: "http consulta #{unique()}", meta_fixture_cliente_edad: 30, meta_fixture_cliente_venta: Decimal.new("100.00")},
        attrs
      )
    )
    |> Ecto.Changeset.put_change(:insert_guid, guid())
    |> Repo.insert!()
  end

  defp criar_consulta(nombre \\ nil) do
    nombre = nombre || "consulta_api_test_#{unique()}"

    {:ok, {header, _}} =
      MetaSchemaContext.crear_header_con_detalles(%{
        "schema_context_name" => nombre,
        "schema_context_label" => "Consulta API test",
        "schema_context_nav" => "/#{nombre}",
        "schema_visible" => true,
        "schema_context_type" => 3,
        "detalles" => []
      })

    {:ok, consulta} = MetaConsultas.crear(header, "meta_fixture_cliente")
    {header, consulta}
  end

  describe "GET /api/:tabla contra una Consulta Ecto" do
    test "trae meta_campos, data (con clave namespaced) y paginación", %{conn: conn} do
      {header, _consulta} = criar_consulta()
      fixture_cliente(%{meta_fixture_cliente_nombre: "Cliente Uno"})

      conn = get(conn, ~p"/api/#{header.schema_context_name}")

      assert %{"meta_campos" => meta_campos, "data" => [fila], "paginacion" => paginacion} = json_response(conn, 200)

      assert Enum.any?(meta_campos, &(&1["campo"] == "meta_fixture_cliente_nombre"))
      assert fila["meta_fixture_cliente__meta_fixture_cliente_nombre"] == "Cliente Uno"
      assert paginacion["total_filas"] == 1
    end

    test "una columna oculta (visible=false) en Get Config no viene en meta_campos ni en data", %{conn: conn} do
      {header, consulta} = criar_consulta()
      fixture_cliente(%{})

      campos = Enum.map(consulta.campos, fn c -> if c["campo"] == "meta_fixture_cliente_edad", do: Map.put(c, "visible", false), else: c end)
      {:ok, _consulta} = MetaConsultas.actualizar_campos(consulta, campos)

      conn = get(conn, ~p"/api/#{header.schema_context_name}")

      assert %{"meta_campos" => meta_campos, "data" => [fila]} = json_response(conn, 200)
      refute Enum.any?(meta_campos, &(&1["campo"] == "meta_fixture_cliente_edad"))
      refute Map.has_key?(fila, "meta_fixture_cliente__meta_fixture_cliente_edad")
    end

    test "filtra por igualdad exacta vía query string, mismo criterio que un catálogo normal", %{conn: conn} do
      {header, _consulta} = criar_consulta()
      fixture_cliente(%{meta_fixture_cliente_nombre: "Buscado", meta_fixture_cliente_edad: 40})
      fixture_cliente(%{meta_fixture_cliente_nombre: "Otro", meta_fixture_cliente_edad: 20})

      conn = get(conn, ~p"/api/#{header.schema_context_name}?meta_fixture_cliente_edad=40")

      assert %{"data" => [fila], "paginacion" => paginacion} = json_response(conn, 200)
      assert paginacion["total_filas"] == 1
      assert fila["meta_fixture_cliente__meta_fixture_cliente_nombre"] == "Buscado"
    end

    test "suma totales solo de las columnas marcadas totalizar", %{conn: conn} do
      {header, consulta} = criar_consulta()
      fixture_cliente(%{meta_fixture_cliente_edad: 10})
      fixture_cliente(%{meta_fixture_cliente_edad: 25})

      campos = Enum.map(consulta.campos, fn c -> if c["campo"] == "meta_fixture_cliente_edad", do: Map.put(c, "totalizar", true), else: c end)
      {:ok, _consulta} = MetaConsultas.actualizar_campos(consulta, campos)

      conn = get(conn, ~p"/api/#{header.schema_context_name}")

      assert %{"totales" => totales} = json_response(conn, 200)
      assert totales["meta_fixture_cliente__meta_fixture_cliente_edad"] == 35
    end

    test "una Consulta sin filas responde 200 con data vacía (no 404)", %{conn: conn} do
      {header, _consulta} = criar_consulta()

      conn = get(conn, ~p"/api/#{header.schema_context_name}")

      assert %{"data" => [], "paginacion" => paginacion} = json_response(conn, 200)
      assert paginacion["total_filas"] == 0
      assert paginacion["total_paginas"] == 1
    end
  end
end
