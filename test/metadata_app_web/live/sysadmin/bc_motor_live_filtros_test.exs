defmodule MetadataAppWeb.Sysadmin.BcMotorLiveFiltrosTest do
  @moduledoc """
  Modal "Filtros" de un campo referencia (SPEC-SYS-1109202601 R7/R24/R28):
  cascada + filtros fijos, incluido un destino de sistema (Almacén), que
  antes de esto tronaba el modal al abrirlo.
  """
  use MetadataAppWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import MetadataApp.AutenticacionFixtures

  alias MetadataApp.Repo
  alias MetadataApp.Autenticacion
  alias MetadataApp.Autenticacion.{Empresa, Rol, UsuarioEmpresa}
  alias MetadataApp.BusinessProcessBuilder.MetaSchema.{Header, Detail}

  @campo "meta_fixture_cliente_edad"

  setup %{conn: conn} do
    usuario = usuario_fixture()

    {:ok, empresa} =
      %Empresa{}
      |> Empresa.changeset(%{nombre: "Empresa motor filtros #{System.unique_integer()}"})
      |> Repo.insert()

    {:ok, _} =
      %UsuarioEmpresa{}
      |> UsuarioEmpresa.changeset(%{usuario_id: usuario.id, empresa_id: empresa.id})
      |> Repo.insert()

    rol_admin = Repo.get_by!(Rol, nombre: "administrador")
    {:ok, _} = MetadataApp.Permissions.asignar_rol(usuario.id, rol_admin.id, empresa.id)

    {:ok, branch} = Autenticacion.crear_branch(%{empresa_id: empresa.id, branch_name: "Toluca"})

    {:ok, _} =
      Autenticacion.crear_inventory_location(%{
        empresa_id: empresa.id,
        branch_id: branch.id,
        inventory_name: "Rutas",
        inventory_type: "COMPROMETIDA"
      })

    # Solo la METADATA del campo "edad" del fixture pasa a ser una
    # referencia a Almacén (tabla de sistema) — es lo único que mira el modal.
    header = Repo.get_by!(Header, schema_context_name: "meta_fixture_cliente")
    detalle = Repo.get_by!(Detail, meta_schema_header_id: header.id, schema_context_field: @campo)

    props =
      detalle.schema_context_properties
      |> Map.put("tipo", "referencia")
      |> Map.put("catalogo", "meta_schema_inventory_location")

    detalle |> Ecto.Changeset.change(%{schema_context_properties: props}) |> Repo.update!()

    conn =
      conn |> log_in_usuario(usuario) |> Plug.Conn.put_session(:empresa_activa_id, empresa.id)

    %{conn: conn, detalle: detalle}
  end

  defp abrir_modal(conn) do
    {:ok, view, _html} = live(conn, ~p"/sysadmin/bc-list/meta_fixture_cliente/motor")
    view |> element("#filtros-#{@campo}") |> render_click()
    view
  end

  test "abre con un destino de sistema, sugiere valores reales y guarda el filtro normalizado", %{
    conn: conn,
    detalle: detalle
  } do
    view = abrir_modal(conn)
    assert has_element?(view, "#form-filtros-referencia")

    view |> element("#agregar-filtro-fijo") |> render_click()
    assert has_element?(view, "#filtro-fijo-0")

    view
    |> form("#form-filtros-referencia", %{
      "filtros_fijos" => %{
        "0" => %{"campo" => "inventory_type", "valores" => " comprometida , disponible"}
      }
    })
    |> render_change()

    assert has_element?(view, "#sugerencias-filtro-0 option[value=COMPROMETIDA]")

    view |> form("#form-filtros-referencia") |> render_submit()

    refute has_element?(view, "#form-filtros-referencia")
    assert has_element?(view, "#filtros-#{@campo}", "Filtros ✓")

    props = Repo.get!(Detail, detalle.id).schema_context_properties

    assert props["filtros_fijos"] == [
             %{"campo" => "inventory_type", "valores" => ["COMPROMETIDA", "DISPONIBLE"]}
           ]
  end

  test "rechaza un filtro sin valores y no guarda nada", %{conn: conn, detalle: detalle} do
    view = abrir_modal(conn)
    view |> element("#agregar-filtro-fijo") |> render_click()

    view
    |> form("#form-filtros-referencia", %{
      "filtros_fijos" => %{"0" => %{"campo" => "inventory_type", "valores" => "  "}}
    })
    |> render_change()

    view |> form("#form-filtros-referencia") |> render_submit()

    assert has_element?(view, "#filtros-referencia-error")
    refute Map.has_key?(Repo.get!(Detail, detalle.id).schema_context_properties, "filtros_fijos")
  end

  test "quitar el último filtro y guardar borra la clave", %{conn: conn, detalle: detalle} do
    detalle = Repo.get!(Detail, detalle.id)

    props =
      Map.put(detalle.schema_context_properties, "filtros_fijos", [
        %{"campo" => "inventory_type", "valores" => ["COMPROMETIDA"]}
      ])

    detalle |> Ecto.Changeset.change(%{schema_context_properties: props}) |> Repo.update!()

    view = abrir_modal(conn)
    assert has_element?(view, "#filtro-fijo-0")

    view |> element("#filtro-fijo-0 button[phx-click=filtro_fijo_quitar]") |> render_click()
    view |> form("#form-filtros-referencia") |> render_submit()

    refute Map.has_key?(Repo.get!(Detail, detalle.id).schema_context_properties, "filtros_fijos")
  end
end
