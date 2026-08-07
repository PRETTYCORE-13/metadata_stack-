defmodule MetadataApp.IntegracionesReglasPostTest do
  @moduledoc """
  Fase 5 de "Integraciones" (2026-08-07) — prueba de punta a punta que una
  regla post puede llamar MetadataApp.Integraciones.ejecutar/2 de forma
  SÍNCRONA, dentro de la misma transacción de la transición (ver
  MetadataApp.MetaBusinessProcess.Reglas.MetaFixtureCliente.Post, en
  test/support), y que:

    - si la API externa responde bien, la transición se aplica normal.
    - si la API externa falla, la transacción entera se revierte -- el
      registro se queda en el estado_id original, no a medias.

  Llama httpbin.org real (mismo criterio que la Fase 4) -- sin mocks, para
  probar el camino real incluyendo el `retry: false` de Req.
  """
  use MetadataAppWeb.ConnCase, async: true

  alias MetadataApp.Repo
  alias MetadataApp.Autenticacion.{Empresa, Rol, UsuarioEmpresa}
  alias MetadataApp.BusinessProcessBuilder.MetaSchema.Header
  alias MetadataApp.MetaSchema.{Estado, Transicion}
  alias MetadataApp.MetaBusinessProcess.Catalogos.MetaFixtureCliente
  alias MetadataApp.Permissions
  alias MetadataApp.Integraciones

  import MetadataApp.AutenticacionFixtures

  setup %{conn: conn} do
    usuario = usuario_fixture()

    {:ok, empresa} =
      %Empresa{} |> Empresa.changeset(%{nombre: "Empresa fixture #{System.unique_integer()}"}) |> Repo.insert()

    {:ok, _} =
      %UsuarioEmpresa{} |> UsuarioEmpresa.changeset(%{usuario_id: usuario.id, empresa_id: empresa.id}) |> Repo.insert()

    rol_admin = Repo.get_by!(Rol, nombre: "administrador")
    {:ok, _} = Permissions.asignar_rol(usuario.id, rol_admin.id, empresa.id)

    conn =
      conn
      |> log_in_usuario(usuario)
      |> Plug.Conn.put_session(:empresa_activa_id, empresa.id)

    %{conn: conn}
  end

  defp guid, do: Ecto.UUID.generate() |> String.replace("-", "")
  defp unique, do: System.unique_integer([:positive])

  defp header_clientes, do: Repo.get_by!(Header, schema_context_name: "meta_fixture_cliente")

  defp fixture_estado(header, attrs) do
    %Estado{}
    |> Estado.changeset(Map.merge(%{meta_schema_header_id: header.id, orden: unique()}, attrs))
    |> Ecto.Changeset.put_change(:insert_guid, guid())
    |> Repo.insert!()
  end

  defp fixture_transicion(header, origen, destino, accion) do
    Permissions.crear_permiso(%{recurso: header.schema_context_name, accion: accion})

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

  defp fixture_credencial do
    {:ok, credencial} =
      Integraciones.crear_credencial(%{
        nombre: "httpbin fixture #{unique()}",
        sistema_externo: "httpbin",
        api_key_nuevo: "clave-de-prueba",
        base_url: "https://httpbin.org"
      })

    credencial
  end

  defp fixture_accion(header, credencial, url_template) do
    {:ok, accion} =
      Integraciones.crear_accion(%{
        meta_schema_header_id: header.id,
        credencial_id: credencial.id,
        nombre: "validar_externo",
        metodo: "GET",
        url_template: url_template
      })

    accion
  end

  describe "regla post síncrona -> Integraciones.ejecutar/2 (dentro de la transacción)" do
    @describetag :external_http

    test "éxito de la API externa: la transición se aplica normal", %{conn: conn} do
      header = header_clientes()
      nuevo = fixture_estado(header, %{nombre: "post_ok_nuevo_#{unique()}", es_inicial: true})
      activo = fixture_estado(header, %{nombre: "post_ok_activo_#{unique()}"})
      fixture_transicion(header, nuevo, activo, "activar_con_integracion")

      credencial = fixture_credencial()
      fixture_accion(header, credencial, "{base_url}/status/200")

      cliente = fixture_cliente(nuevo.id)

      conn = post(conn, ~p"/api/meta_fixture_cliente/#{cliente.id}/transiciones/activar_con_integracion", %{})

      assert %{"data" => data} = json_response(conn, 200)
      assert data["estado_id"] == activo.id
    end

    test "falla de la API externa: la transacción entera se revierte", %{conn: conn} do
      header = header_clientes()
      nuevo = fixture_estado(header, %{nombre: "post_fail_nuevo_#{unique()}", es_inicial: true})
      activo = fixture_estado(header, %{nombre: "post_fail_activo_#{unique()}"})
      fixture_transicion(header, nuevo, activo, "activar_con_integracion")

      credencial = fixture_credencial()
      fixture_accion(header, credencial, "{base_url}/status/500")

      cliente = fixture_cliente(nuevo.id)

      conn = post(conn, ~p"/api/meta_fixture_cliente/#{cliente.id}/transiciones/activar_con_integracion", %{})

      assert %{"errors" => %{"detail" => _}} = json_response(conn, 500)

      # La prueba real de la reversión: releer de la base, no confiar en el
      # `cliente` en memoria -- si el Multi hubiera hecho commit parcial
      # (el bug que esta prueba existe para prevenir), esto lo mostraría.
      recargado = Repo.get!(MetaFixtureCliente, cliente.id)
      assert recargado.estado_id == nuevo.id
    end
  end
end
