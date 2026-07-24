defmodule MetadataAppWeb.CatalogoLiveTest do
  use MetadataAppWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Ecto.Changeset

  alias MetadataApp.Repo
  alias MetadataApp.BusinessProcessBuilder.MetaSchema.Header
  alias MetadataApp.MetaBusinessProcess.Catalogos.MetaFixtureCliente
  alias MetadataApp.MetaSchema.Estado

  defp guid, do: Ecto.UUID.generate() |> String.replace("-", "")
  defp unique, do: System.unique_integer([:positive])

  # meta_fixture_cliente es un catálogo permanente sembrado por migración
  # (ver priv/repo/migrations/20260723220000_crear_fixtures_de_test.exs) —
  # mismo catálogo que ya usa el resto del test suite del motor
  # (catalogo_generico_test.exs, campos_editables_test.exs, etc.), en vez
  # de crear un Header aislado por test: los pty_* que este archivo usaba
  # antes (pty_demo_celulares) se borraron de git en la limpieza 2026-07-23.
  defp header_cliente, do: Repo.get_by!(Header, schema_context_name: "meta_fixture_cliente")

  defp fixture_cliente(overrides) do
    base = %{
      meta_fixture_cliente_nombre: "cliente_#{unique()}",
      meta_fixture_cliente_edad: 30,
      meta_fixture_cliente_venta: Decimal.new("100.00")
    }

    %MetaFixtureCliente{}
    |> MetaFixtureCliente.changeset(Map.merge(base, overrides))
    |> put_change(:insert_guid, guid())
    |> Repo.insert!()
  end

  test "clic en una fila abre el modal con los campos editables precargados", %{conn: conn} do
    header = header_cliente()
    cliente = fixture_cliente(%{meta_fixture_cliente_nombre: "Galaxy A55"})

    {:ok, view, _html} = live(conn, header.schema_context_nav)

    html = view |> element("tr[phx-value-id='#{cliente.id}']") |> render_click()

    assert html =~ "Editar registro #{cliente.id}"
    assert html =~ "Galaxy A55"
  end

  test "guardar la edición actualiza el registro y se refleja en la tabla", %{conn: conn} do
    header = header_cliente()
    cliente = fixture_cliente(%{meta_fixture_cliente_nombre: "Modelo viejo"})

    {:ok, view, _html} = live(conn, header.schema_context_nav)

    view |> element("tr[phx-value-id='#{cliente.id}']") |> render_click()

    html =
      view
      |> form("form[phx-submit='guardar_edicion']", %{
        "registro" => %{
          "meta_fixture_cliente_nombre" => "Modelo nuevo",
          "meta_fixture_cliente_edad" => "40",
          "meta_fixture_cliente_venta" => "999.50"
        }
      })
      |> render_submit()

    refute html =~ "Editar registro"
    assert html =~ "Modelo nuevo"
    refute html =~ "Modelo viejo"

    actualizado = Repo.get!(MetaFixtureCliente, cliente.id)
    assert actualizado.meta_fixture_cliente_nombre == "Modelo nuevo"
    assert actualizado.meta_fixture_cliente_edad == 40
  end

  test "cancelar cierra el modal sin guardar nada", %{conn: conn} do
    header = header_cliente()
    cliente = fixture_cliente(%{meta_fixture_cliente_nombre: "Sin cambios"})

    {:ok, view, _html} = live(conn, header.schema_context_nav)

    view |> element("tr[phx-value-id='#{cliente.id}']") |> render_click()
    html = view |> element("button", "Cancelar") |> render_click()

    refute html =~ "Editar registro"
    assert Repo.get!(MetaFixtureCliente, cliente.id).meta_fixture_cliente_nombre == "Sin cambios"
  end

  test "un valor inválido muestra el error y no guarda", %{conn: conn} do
    header = header_cliente()
    cliente = fixture_cliente(%{meta_fixture_cliente_nombre: "Original"})

    {:ok, view, _html} = live(conn, header.schema_context_nav)

    view |> element("tr[phx-value-id='#{cliente.id}']") |> render_click()

    html =
      view
      |> form("form[phx-submit='guardar_edicion']", %{
        "registro" => %{
          "meta_fixture_cliente_nombre" => "",
          "meta_fixture_cliente_edad" => "40",
          "meta_fixture_cliente_venta" => "999.50"
        }
      })
      |> render_submit()

    assert html =~ "Editar registro"
    assert Repo.get!(MetaFixtureCliente, cliente.id).meta_fixture_cliente_nombre == "Original"
  end

  test "catálogo con motor de estados pero sin transición guardar resuelta: nada es editable", %{conn: conn} do
    header = header_cliente()

    estado =
      %Estado{}
      |> Estado.changeset(%{meta_schema_header_id: header.id, nombre: "activo_#{unique()}", orden: unique(), es_inicial: true})
      |> put_change(:insert_guid, guid())
      |> Repo.insert!()

    cliente = fixture_cliente(%{})
    cliente = cliente |> change(%{estado_id: estado.id}) |> Repo.update!()

    {:ok, view, _html} = live(conn, header.schema_context_nav)

    html = view |> element("tr[phx-value-id='#{cliente.id}']") |> render_click()

    assert html =~ "no se puede editar en su estado actual"
    refute html =~ "name=\"registro[meta_fixture_cliente_nombre]\""
  end
end
