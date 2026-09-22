defmodule MetadataAppWeb.MetaTransicionControllerTest do
  use MetadataAppWeb.ConnCase, async: true

  alias MetadataApp.Repo
  alias MetadataApp.Autenticacion.{Empresa, Rol, UsuarioEmpresa}
  alias MetadataApp.BusinessProcessBuilder.MetaSchema.Header
  alias MetadataApp.MetaSchema.{Estado, Transicion}
  alias MetadataApp.MetaBusinessProcess.Catalogos.MetaFixtureCliente
  alias MetadataApp.Permissions

  import MetadataApp.AutenticacionFixtures

  # RBAC (Fase 2, automático 2026-07-26): toda transición exige permiso —
  # sin esto, cualquier POST/GET de este archivo caería en "sin permiso"
  # sin importar lo que la prueba en realidad quiere ejercitar (precondición
  # de negocio, no autorización — eso ya lo cubre permissions_test.exs).
  # administrador ve cualquier permiso YA REGISTRADO sin necesitar
  # rol_permiso explícito, así que alcanza con loguearse como tal y con que
  # `fixture_transicion/4` registre el permiso de cada acción que crea.
  setup %{conn: conn} do
    usuario = usuario_fixture()

    {:ok, empresa} =
      %Empresa{} |> Empresa.changeset(%{nombre: "Empresa fixture #{System.unique_integer()}"}) |> Repo.insert()

    {:ok, _} =
      %UsuarioEmpresa{} |> UsuarioEmpresa.changeset(%{usuario_id: usuario.id, empresa_id: empresa.id}) |> Repo.insert()

    rol_admin = Repo.get_by!(Rol, nombre: "administrador")
    {:ok, _} = Permissions.asignar_rol(usuario.id, rol_admin.id, empresa.id)

    # SPEC-SYS-2209202601 -- GET .../transiciones (listar) ahora exige
    # {recurso: "meta_fixture_cliente", accion: "leer"} vía el plug
    # nuevo; administrador solo ve permisos YA REGISTRADOS (ver
    # comentario de arriba), así que hay que registrar este también,
    # no solo los de cada transición puntual (fixture_transicion/4).
    Permissions.crear_permiso(%{recurso: "meta_fixture_cliente", accion: "leer"})

    conn =
      conn
      |> log_in_usuario(usuario)
      |> Plug.Conn.put_session(:empresa_activa_id, empresa.id)

    %{conn: conn, usuario: usuario, empresa: empresa}
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

  # Sin `reglas`: el mecanismo actual (un módulo Pre por catálogo, ver
  # test/support/reglas_meta_fixture_cliente.ex) despacha por el nombre de
  # `accion` en código, no por filas en la base — el TransicionRegla que
  # existía acá antes ya no tiene ningún uso real fuera de tests viejos.
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

    # SPEC-SYS-2209202601: una "accion" que no existe como transición
    # tampoco existe como Permiso -- el plug de autorización (R6, chequea
    # el permiso de "no_existe") ahora corta ANTES de que el controller
    # llegue a evaluar si es estructuralmente válida. 403, no 409 -- este
    # test dejó de poder ejercitar el rechazo estructural del controller
    # (eso lo sigue cubriendo directo `MetaStateEngineTest`).
    test "acción sin permiso registrado (inexistente) -> 403, nunca llega al controller", %{conn: conn} do
      header = header_clientes()
      nuevo = fixture_estado(header, %{nombre: "http_409a_#{unique()}", es_inicial: true})
      cliente = fixture_cliente(nuevo.id)

      conn = post(conn, ~p"/api/meta_fixture_cliente/#{cliente.id}/transiciones/no_existe", %{})

      assert %{"errors" => %{"detail" => "sin permiso"}} = json_response(conn, 403)
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

  describe "autorización (SPEC-SYS-2209202601, R6)" do
    import MetadataApp.PermisosApiFixtures

    test "sin sesión -> 401, ni index ni ejecutar tocan el motor de estados" do
      conn = Phoenix.ConnTest.build_conn()
      header = header_clientes()
      nuevo = fixture_estado(header, %{nombre: "http_401_#{unique()}", es_inicial: true})
      cliente = fixture_cliente(nuevo.id)

      assert %{"errors" => %{"detail" => "no autenticado"}} =
               get(conn, ~p"/api/meta_fixture_cliente/#{cliente.id}/transiciones") |> json_response(401)

      assert %{"errors" => %{"detail" => "no autenticado"}} =
               post(conn, ~p"/api/meta_fixture_cliente/#{cliente.id}/transiciones/activar", %{}) |> json_response(401)
    end

    test "con sesión pero sin permiso para ESA transición puntual -> 403 (nunca llega a verificar_permiso_transicion/3)" do
      empresa = empresa_fixture!()
      # tiene permiso para "activar" pero no para "baja" -- confirma que el chequeo
      # es por transición puntual (conn.params["accion"]), no "cualquier transición del catálogo".
      usuario = usuario_con_permiso!(empresa, "meta_fixture_cliente", "activar")
      conn = conn_autenticado(Phoenix.ConnTest.build_conn(), usuario, empresa)

      header = header_clientes()
      nuevo = fixture_estado(header, %{nombre: "http_403tr_#{unique()}", es_inicial: true})
      activo = fixture_estado(header, %{nombre: "http_403tr2_#{unique()}"})
      fixture_transicion(header, nuevo, activo, "baja")
      cliente = fixture_cliente(nuevo.id)

      assert %{"errors" => %{"detail" => "sin permiso"}} =
               post(conn, ~p"/api/meta_fixture_cliente/#{cliente.id}/transiciones/baja", %{}) |> json_response(403)
    end
  end
end
