defmodule MetadataAppWeb.Sysadmin.BcMotorLiveDiccionarioTest do
  @moduledoc "SPEC-SYS-1109202601 §2.2 (R31-R34): sección \"Filtrar por diccionario\" del modal Filtros."
  use MetadataAppWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import MetadataApp.AutenticacionFixtures

  alias MetadataApp.{Repo, ConsultasSql}
  alias MetadataApp.Autenticacion.{Empresa, Rol, UsuarioEmpresa}
  alias MetadataApp.BusinessProcessBuilder.MetaSchema.{Header, Detail}
  alias MetadataApp.MetaBusinessProcess.Catalogos.MetaFixtureEquipo

  @campo "meta_fixture_cliente_edad"

  setup %{conn: conn} do
    usuario = usuario_fixture()
    {:ok, empresa} = %Empresa{} |> Empresa.changeset(%{nombre: "Empresa dic #{System.unique_integer()}"}) |> Repo.insert()
    {:ok, _} = %UsuarioEmpresa{} |> UsuarioEmpresa.changeset(%{usuario_id: usuario.id, empresa_id: empresa.id}) |> Repo.insert()
    rol_admin = Repo.get_by!(Rol, nombre: "administrador")
    {:ok, _} = MetadataApp.Permissions.asignar_rol(usuario.id, rol_admin.id, empresa.id)

    header = Repo.get_by!(Header, schema_context_name: "meta_fixture_cliente")
    detalle = Repo.get_by!(Detail, meta_schema_header_id: header.id, schema_context_field: @campo)
    props = detalle.schema_context_properties |> Map.put("tipo", "referencia") |> Map.put("catalogo", "meta_fixture_equipo")
    detalle |> Ecto.Changeset.change(%{schema_context_properties: props}) |> Repo.update!()

    s = System.unique_integer([:positive])

    %MetaFixtureEquipo{}
    |> MetaFixtureEquipo.changeset(%{meta_fixture_equipo_nombre_equipo: "Dic modal #{s}"})
    |> Ecto.Changeset.change(%{insert_guid: Ecto.UUID.generate() |> String.replace("-", "")})
    |> Repo.insert!()

    {:ok, {dic, _}} = ConsultasSql.crear(%{"etiqueta" => "Equipos modal", "nav" => "/equipos_modal_#{s}"})

    {:ok, _} =
      ConsultasSql.guardar_sql(
        dic.schema_context_name,
        "SELECT id, meta_fixture_equipo_nombre_equipo AS nombre FROM meta_fixture_equipo WHERE meta_fixture_equipo_nombre_equipo LIKE 'Dic modal #{s}%'"
      )

    {:ok, _} = ConsultasSql.autorizar_bc(dic.schema_context_name, "meta_fixture_cliente")

    conn = conn |> log_in_usuario(usuario) |> Plug.Conn.put_session(:empresa_activa_id, empresa.id)
    %{conn: conn, detalle: detalle, dic: dic.schema_context_name}
  end

  defp abrir_modal(conn) do
    {:ok, view, _html} = live(conn, ~p"/sysadmin/bc-list/meta_fixture_cliente/motor")
    view |> element("#filtros-#{@campo}") |> render_click()
    view
  end

  test "elegir un Diccionario y su descripción lo guarda en el campo", %{conn: conn, detalle: detalle, dic: dic} do
    view = abrir_modal(conn)
    assert has_element?(view, "#selector-diccionario option[value=#{dic}]")

    view |> form("#form-filtros-referencia", %{"diccionario" => %{"consulta" => dic}}) |> render_change()
    view |> form("#form-filtros-referencia", %{"diccionario" => %{"consulta" => dic, "descripcion" => ["nombre"]}}) |> render_change()
    view |> form("#form-filtros-referencia") |> render_submit()

    refute has_element?(view, "#form-filtros-referencia")
    assert has_element?(view, "#filtros-#{@campo}", "Filtros ✓")
    assert Repo.get!(Detail, detalle.id).schema_context_properties["diccionario"] == %{"consulta" => dic, "descripcion" => ["nombre"]}
  end

  test "sin columna de descripción no guarda", %{conn: conn, detalle: detalle, dic: dic} do
    view = abrir_modal(conn)
    view |> form("#form-filtros-referencia", %{"diccionario" => %{"consulta" => dic}}) |> render_change()
    view |> form("#form-filtros-referencia") |> render_submit()

    assert has_element?(view, "#filtros-referencia-error")
    refute Map.has_key?(Repo.get!(Detail, detalle.id).schema_context_properties, "diccionario")
  end
end
