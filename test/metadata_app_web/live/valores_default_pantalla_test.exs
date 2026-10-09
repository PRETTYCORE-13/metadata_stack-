defmodule MetadataAppWeb.ValoresDefaultPantallaTest do
  @moduledoc """
  SPEC-SYS-1109202601 §2.4: el alta de la Ficha abre con el valor default ya
  capturado (R44) y el Motor rechaza un default inválido con el motivo
  (R43). Escenario: meta_fixture_cliente con transición alta.
  """
  use MetadataAppWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import MetadataApp.AutenticacionFixtures

  alias MetadataApp.{Permissions, Repo}
  alias MetadataApp.Autenticacion.{Empresa, Rol, UsuarioEmpresa}
  alias MetadataApp.BusinessProcessBuilder.MetaSchemaContext
  alias MetadataApp.BusinessProcessBuilder.MetaSchema.Header
  alias MetadataApp.MetaSchema.{Estado, Transicion}

  @campos ~w(meta_fixture_cliente_nombre meta_fixture_cliente_edad meta_fixture_cliente_venta)

  defp guid, do: Ecto.UUID.generate() |> String.replace("-", "")

  setup %{conn: conn} do
    usuario = usuario_fixture()
    {:ok, empresa} = %Empresa{} |> Empresa.changeset(%{nombre: "Empresa defaults #{System.unique_integer()}"}) |> Repo.insert()
    {:ok, _} = %UsuarioEmpresa{} |> UsuarioEmpresa.changeset(%{usuario_id: usuario.id, empresa_id: empresa.id}) |> Repo.insert()
    {:ok, _} = Permissions.asignar_rol(usuario.id, Repo.get_by!(Rol, nombre: "administrador").id, empresa.id)

    header = Repo.get_by!(Header, schema_context_name: "meta_fixture_cliente")

    estado =
      %Estado{}
      |> Estado.changeset(%{meta_schema_header_id: header.id, nombre: "activo_def_#{System.unique_integer([:positive])}", es_inicial: true, orden: 1})
      |> Ecto.Changeset.put_change(:insert_guid, guid())
      |> Repo.insert!()

    %Transicion{}
    |> Transicion.changeset(%{
      meta_schema_header_id: header.id,
      accion: "alta",
      etiqueta: "Alta",
      estado_origen_id: nil,
      estado_destino_id: estado.id,
      campos_editables: @campos
    })
    |> Ecto.Changeset.put_change(:insert_guid, guid())
    |> Repo.insert!()

    [edad] = MetaSchemaContext.listar_detalles("meta_fixture_cliente") |> Enum.filter(&(&1.schema_context_field == "meta_fixture_cliente_edad"))

    {:ok, _} =
      MetaSchemaContext.actualizar_detalle(edad, %{
        "schema_context_properties" => Map.put(edad.schema_context_properties, "valor_default", "33")
      })

    conn = conn |> log_in_usuario(usuario) |> Plug.Conn.put_session(:empresa_activa_id, empresa.id)
    %{conn: conn}
  end

  test "el alta abre con el valor default capturado (R44)", %{conn: conn} do
    {:ok, view, _} = live(conn, "/registro/meta_fixture_cliente/nuevo")
    assert has_element?(view, ~s(input[name="campos[meta_fixture_cliente_edad]"][value="33"]))
  end

  test "el Motor rechaza un default inválido con el motivo (R43)", %{conn: conn} do
    {:ok, view, _} = live(conn, "/sysadmin/bc-list/meta_fixture_cliente/motor")

    html =
      view
      |> form("#default-meta_fixture_cliente_edad", %{"campo" => "meta_fixture_cliente_edad", "valor_default" => "treinta"})
      |> render_change()

    assert html =~ "no válido: debe ser un número entero"
  end
end
