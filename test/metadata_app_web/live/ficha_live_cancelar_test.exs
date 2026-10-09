defmodule MetadataAppWeb.FichaLiveCancelarTest do
  @moduledoc """
  "Cancelar" de la ficha descarta TODO lo no guardado: campos del
  encabezado y renglones nuevos/editados/eliminados del tab Detalle (bug
  real 2026-09-25: con un renglón nuevo pendiente el contador decía "1
  cambio sin guardar" pero Cancelar quedaba deshabilitado).
  """
  use MetadataAppWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import MetadataApp.AutenticacionFixtures
  import Ecto.Query

  alias MetadataApp.Repo
  alias MetadataApp.Autenticacion.{Empresa, Rol, UsuarioEmpresa}
  alias MetadataApp.BusinessProcessBuilder.MetaSchema.Header
  alias MetadataApp.MetaSchema.{Estado, Transicion}
  alias MetadataApp.Permissions

  @campos ~w(meta_fixture_cliente_nombre meta_fixture_cliente_edad meta_fixture_cliente_venta)

  defp guid, do: Ecto.UUID.generate() |> String.replace("-", "")

  defp transicion(header, accion, origen, destino) do
    %Transicion{}
    |> Transicion.changeset(%{
      meta_schema_header_id: header.id,
      accion: accion,
      etiqueta: String.capitalize(accion),
      estado_origen_id: origen,
      estado_destino_id: destino,
      campos_editables: @campos
    })
    |> Ecto.Changeset.put_change(:insert_guid, guid())
    |> Repo.insert!()
  end

  setup %{conn: conn} do
    usuario = usuario_fixture()
    {:ok, empresa} = %Empresa{} |> Empresa.changeset(%{nombre: "Empresa cancelar #{System.unique_integer()}"}) |> Repo.insert()
    {:ok, _} = %UsuarioEmpresa{} |> UsuarioEmpresa.changeset(%{usuario_id: usuario.id, empresa_id: empresa.id}) |> Repo.insert()
    {:ok, _} = Permissions.asignar_rol(usuario.id, Repo.get_by!(Rol, nombre: "administrador").id, empresa.id)

    header = Repo.get_by!(Header, schema_context_name: "meta_fixture_cliente")

    estado =
      %Estado{}
      |> Estado.changeset(%{meta_schema_header_id: header.id, nombre: "activo_cancelar_#{System.unique_integer([:positive])}", es_inicial: true, orden: 1})
      |> Ecto.Changeset.put_change(:insert_guid, guid())
      |> Repo.insert!()

    transicion(header, "alta", nil, estado.id)
    transicion(header, "guardar", estado.id, estado.id)

    conn = conn |> log_in_usuario(usuario) |> Plug.Conn.put_session(:empresa_activa_id, empresa.id)

    nombre = "Cancelar #{System.unique_integer([:positive])}"
    campos = %{"meta_fixture_cliente_nombre" => nombre, "meta_fixture_cliente_edad" => "40", "meta_fixture_cliente_venta" => "10.00"}
    {:ok, alta, _} = live(conn, "/registro/meta_fixture_cliente/nuevo")
    render_change(alta, "validar", %{"campos" => campos})
    alta |> form("#form-ficha-datos", %{"campos" => campos}) |> render_submit()

    registro =
      MetadataApp.MetaBusinessProcess.Catalogos.MetaFixtureCliente
      |> where([r], r.meta_fixture_cliente_nombre == ^nombre)
      |> Repo.one!()

    %{conn: conn, registro: registro}
  end

  test "un renglón nuevo pendiente habilita Cancelar, y Cancelar lo descarta", %{conn: conn, registro: registro} do
    {:ok, view, _} = live(conn, "/registro/meta_fixture_cliente/#{registro.id}")
    assert has_element?(view, "#ficha-cancelar[disabled]")

    render_hook(view, "grid_sync", %{"catalogo" => "detalle_x", "nuevas" => [%{"campo" => "valor"}], "editadas" => [], "eliminadas" => []})
    assert render(view) =~ "1 cambio sin guardar"
    refute has_element?(view, "#ficha-cancelar[disabled]")

    view |> element("#ficha-cancelar") |> render_click()
    refute render(view) =~ "cambio sin guardar"
    assert has_element?(view, "#ficha-cancelar[disabled]")
  end

  test "Cancelar también descarta lo tipeado en el encabezado", %{conn: conn, registro: registro} do
    {:ok, view, _} = live(conn, "/registro/meta_fixture_cliente/#{registro.id}")

    render_change(view, "validar", %{"campos" => %{"meta_fixture_cliente_nombre" => "Otro nombre"}})
    refute has_element?(view, "#ficha-cancelar[disabled]")

    view |> element("#ficha-cancelar") |> render_click()
    assert has_element?(view, "#ficha-cancelar[disabled]")
  end
end
