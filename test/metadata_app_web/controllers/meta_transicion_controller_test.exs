defmodule MetadataAppWeb.MetaTransicionControllerTest do
  use MetadataAppWeb.ConnCase, async: true

  alias MetadataApp.Repo
  alias MetadataApp.BusinessProcessBuilder.MetaSchema.Header
  alias MetadataApp.MetaSchema.{Estado, Transicion}
  alias MetadataApp.MetaBusinessProcess.Catalogos.MetaFixtureCliente

  defp guid, do: Ecto.UUID.generate() |> String.replace("-", "")
  defp unique, do: System.unique_integer([:positive])

  defp header_clientes, do: Repo.get_by!(Header, schema_context_name: "meta_fixture_cliente")

  defp fixture_estado(header, attrs) do
    %Estado{}
    |> Estado.changeset(Map.merge(%{meta_schema_header_id: header.id, orden: unique()}, attrs))
    |> Ecto.Changeset.put_change(:insert_guid, guid())
    |> Repo.insert!()
  end

  # Sin `reglas`: el mecanismo actual (un módulo Pre por catálogo, ver
  # test/support/reglas_meta_fixture_cliente.ex) despacha por el nombre de
  # `accion` en código, no por filas en la base — el TransicionRegla que
  # existía acá antes ya no tiene ningún uso real fuera de tests viejos.
  defp fixture_transicion(header, origen, destino, accion) do
    %Transicion{}
    |> Transicion.changeset(%{
      meta_schema_header_id: header.id,
      accion: accion,
      etiqueta: String.capitalize(accion),
      estado_origen_id: origen.id,
      estado_destino_id: destino.id
    })
    |> Ecto.Changeset.put_change(:insert_guid, guid())
    |> Repo.insert!()
  end

  defp fixture_cliente(estado_id) do
    %MetaFixtureCliente{}
    |> MetaFixtureCliente.changeset(%{
      meta_fixture_cliente_nombre: "cliente #{unique()}",
      meta_fixture_cliente_edad: 30,
      meta_fixture_cliente_venta: Decimal.new("100.00")
    })
    |> Ecto.Changeset.put_change(:insert_guid, guid())
    |> Ecto.Changeset.put_change(:estado_id, estado_id)
    |> Repo.insert!()
  end

  describe "GET /api/:tabla/:id/transiciones — descubrimiento" do
    test "lista la transición disponible desde el estado actual", %{conn: conn} do
      header = header_clientes()
      nuevo = fixture_estado(header, %{nombre: "http_nuevo_#{unique()}", es_inicial: true})
      activo = fixture_estado(header, %{nombre: "http_activo_#{unique()}"})
      fixture_transicion(header, nuevo, activo, "activar")
      cliente = fixture_cliente(nuevo.id)

      conn = get(conn, ~p"/api/meta_fixture_cliente/#{cliente.id}/transiciones")

      assert %{"data" => [transicion]} = json_response(conn, 200)
      assert transicion["accion"] == "activar"
      assert transicion["disponible"] == true
      assert transicion["razones"] == []
    end

    test "una precondición fallida deja la transición visible pero deshabilitada", %{conn: conn} do
      header = header_clientes()
      nuevo = fixture_estado(header, %{nombre: "http_nuevo2_#{unique()}", es_inicial: true})
      activo = fixture_estado(header, %{nombre: "http_activo2_#{unique()}"})

      fixture_transicion(header, nuevo, activo, "activar_con_dato")

      cliente = fixture_cliente(nuevo.id)

      conn = get(conn, ~p"/api/meta_fixture_cliente/#{cliente.id}/transiciones")

      assert %{"data" => [transicion]} = json_response(conn, 200)
      assert transicion["disponible"] == false
      assert [%{"regla" => "pre", "mensaje" => "falta el dato: motivo"}] = transicion["razones"]
    end

    test "una falla de requiere_rol OCULTA la transición por completo", %{conn: conn} do
      header = header_clientes()
      nuevo = fixture_estado(header, %{nombre: "http_nuevo3_#{unique()}", es_inicial: true})
      activo = fixture_estado(header, %{nombre: "http_activo3_#{unique()}"})

      fixture_transicion(header, nuevo, activo, "activar_con_rol")

      cliente = fixture_cliente(nuevo.id)

      conn = get(conn, ~p"/api/meta_fixture_cliente/#{cliente.id}/transiciones")

      assert %{"data" => []} = json_response(conn, 200)
    end
  end

  describe "POST /api/:tabla/:id/transiciones/:accion — ejecución" do
    test "éxito: 200, registro actualizado + descubrimiento del nuevo estado", %{conn: conn} do
      header = header_clientes()
      nuevo = fixture_estado(header, %{nombre: "http_ej_nuevo_#{unique()}", es_inicial: true})
      activo = fixture_estado(header, %{nombre: "http_ej_activo_#{unique()}"})
      fixture_transicion(header, nuevo, activo, "activar")
      cliente = fixture_cliente(nuevo.id)

      conn = post(conn, ~p"/api/meta_fixture_cliente/#{cliente.id}/transiciones/activar", %{})

      assert %{"data" => data, "transiciones" => transiciones} = json_response(conn, 200)
      assert data["estado_id"] == activo.id
      assert transiciones == []
    end

    test "rechazo estructural: acción inválida desde el estado actual -> 409", %{conn: conn} do
      header = header_clientes()
      nuevo = fixture_estado(header, %{nombre: "http_409a_#{unique()}", es_inicial: true})
      cliente = fixture_cliente(nuevo.id)

      conn = post(conn, ~p"/api/meta_fixture_cliente/#{cliente.id}/transiciones/no_existe", %{})

      assert %{"errors" => %{"detail" => _, "estado_actual_id" => estado_id}} =
               json_response(conn, 409)

      assert estado_id == nuevo.id
    end

    test "rechazo de negocio: precondición fallida -> 422 con razones", %{conn: conn} do
      header = header_clientes()
      nuevo = fixture_estado(header, %{nombre: "http_422_#{unique()}", es_inicial: true})
      activo = fixture_estado(header, %{nombre: "http_422b_#{unique()}"})

      fixture_transicion(header, nuevo, activo, "activar_con_dato")

      cliente = fixture_cliente(nuevo.id)

      conn = post(conn, ~p"/api/meta_fixture_cliente/#{cliente.id}/transiciones/activar_con_dato", %{})

      assert %{"errors" => %{"razones" => [%{"regla" => "pre", "mensaje" => "falta el dato: motivo"}]}} =
               json_response(conn, 422)
    end

    test "pasando el dato requerido en el body, la transición sí se ejecuta", %{conn: conn} do
      header = header_clientes()
      nuevo = fixture_estado(header, %{nombre: "http_ok_dato_#{unique()}", es_inicial: true})
      activo = fixture_estado(header, %{nombre: "http_ok_dato2_#{unique()}"})

      fixture_transicion(header, nuevo, activo, "activar_con_dato")

      cliente = fixture_cliente(nuevo.id)

      conn =
        post(conn, ~p"/api/meta_fixture_cliente/#{cliente.id}/transiciones/activar_con_dato", %{
          "motivo" => "porque sí"
        })

      assert %{"data" => data} = json_response(conn, 200)
      assert data["estado_id"] == activo.id
    end
  end
end
