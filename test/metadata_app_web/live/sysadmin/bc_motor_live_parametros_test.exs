defmodule MetadataAppWeb.Sysadmin.BcMotorLiveParametrosTest do
  @moduledoc """
  SPEC-SYS-0209202601, Grupo D — la grilla "Columnas del GET" de un BC
  ahora tiene Tot./Param/Tipo/Acot./Default (antes solo Consultas los
  tenía). Mismos nombres de evento que consulta_editor_live.ex, acá
  persistidos contra meta_schema_detail (ver ParametrosCatalogoComponents
  y catalogo_desde_id/1 en bc_motor_live.ex).
  """
  use MetadataAppWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import MetadataApp.AutenticacionFixtures

  alias MetadataApp.Repo
  alias MetadataApp.Autenticacion.{Empresa, Rol, UsuarioEmpresa}
  alias MetadataApp.BusinessProcessBuilder.MetaSchemaContext

  setup %{conn: conn} do
    usuario = usuario_fixture()

    {:ok, empresa} =
      %Empresa{} |> Empresa.changeset(%{nombre: "Empresa motor parametros #{System.unique_integer()}"}) |> Repo.insert()

    {:ok, _} =
      %UsuarioEmpresa{} |> UsuarioEmpresa.changeset(%{usuario_id: usuario.id, empresa_id: empresa.id}) |> Repo.insert()

    rol_admin = Repo.get_by!(Rol, nombre: "administrador")
    {:ok, _} = MetadataApp.Permissions.asignar_rol(usuario.id, rol_admin.id, empresa.id)

    conn =
      conn
      |> log_in_usuario(usuario)
      |> Plug.Conn.put_session(:empresa_activa_id, empresa.id)

    %{conn: conn}
  end

  defp detalle(header, campo) do
    Repo.get_by!(MetadataApp.BusinessProcessBuilder.MetaSchema.Detail, meta_schema_header_id: header.id, schema_context_field: campo)
  end

  defp id_compuesto(header, campo), do: "#{header.schema_context_name}::#{campo}"

  test "Param/Tipo/Acotado/Default en un campo string", %{conn: conn} do
    header = MetaSchemaContext.obtener_header_por_nombre("meta_fixture_cliente")

    # visible es requisito para poder prender Parámetro (misma barrera que Consultas)
    {:ok, _} = MetaSchemaContext.actualizar_detalle(detalle(header, "meta_fixture_cliente_nombre"), %{"schema_context_properties" => Map.put(detalle(header, "meta_fixture_cliente_nombre").schema_context_properties, "visible", true)})

    {:ok, view, html} = live(conn, ~p"/sysadmin/bc-list/#{header.schema_context_name}/motor")
    assert html =~ "Param"
    assert html =~ "Tipo"
    assert html =~ "Acot."
    assert html =~ "Default"
    assert html =~ "Tot."

    id = id_compuesto(header, "meta_fixture_cliente_nombre")

    render_click(view, "cambiar_es_parametro", %{"campo" => id})
    assert detalle(header, "meta_fixture_cliente_nombre").schema_context_properties["es_parametro"] == true

    render_change(view, "cambiar_tipo_filtro", %{"tipo_filtro" => %{id => "igual"}})
    assert detalle(header, "meta_fixture_cliente_nombre").schema_context_properties["tipo_filtro"] == "igual"

    render_change(view, "cambiar_defaults_valor", %{"defaults_valor" => %{id => "Juan"}})
    assert detalle(header, "meta_fixture_cliente_nombre").schema_context_properties["defaults"] == %{"valor" => "Juan"}
  end

  test "Acotado + Default en un campo numérico", %{conn: conn} do
    header = MetaSchemaContext.obtener_header_por_nombre("meta_fixture_cliente")
    campo_edad = detalle(header, "meta_fixture_cliente_edad")
    {:ok, _} = MetaSchemaContext.actualizar_detalle(campo_edad, %{"schema_context_properties" => Map.merge(campo_edad.schema_context_properties, %{"visible" => true, "es_parametro" => true})})

    {:ok, view, _html} = live(conn, ~p"/sysadmin/bc-list/#{header.schema_context_name}/motor")
    id = id_compuesto(header, "meta_fixture_cliente_edad")

    render_click(view, "cambiar_acotado", %{"campo" => id})
    assert detalle(header, "meta_fixture_cliente_edad").schema_context_properties["acotado"] == true

    render_change(view, "cambiar_defaults_valor", %{"defaults_valor" => %{id => "18"}})
    render_change(view, "cambiar_defaults_valor_hasta", %{"defaults_valor_hasta" => %{id => "65"}})
    assert detalle(header, "meta_fixture_cliente_edad").schema_context_properties["defaults"] == %{"valor" => "18", "valor_hasta" => "65"}
  end

  test "Totales: toggle principal + sub-opciones en un campo numérico", %{conn: conn} do
    header = MetaSchemaContext.obtener_header_por_nombre("meta_fixture_cliente")

    {:ok, view, _html} = live(conn, ~p"/sysadmin/bc-list/#{header.schema_context_name}/motor")

    render_click(view, "cambiar_agregacion_activa", %{"campo" => "meta_fixture_cliente_venta", "activo" => "true"})
    assert detalle(header, "meta_fixture_cliente_venta").schema_context_properties["agregacion_activa"] == true

    render_click(view, "cambiar_minmax_recomendado", %{"campo" => "meta_fixture_cliente_venta", "recomendado" => "true"})
    assert detalle(header, "meta_fixture_cliente_venta").schema_context_properties["minmax_recomendado"] == true

    render_click(view, "cambiar_total_general", %{"campo" => "meta_fixture_cliente_venta", "activo" => "true"})
    assert detalle(header, "meta_fixture_cliente_venta").schema_context_properties["total_general_activo"] == true

    # limpieza -- no dejar el fixture compartido con Totales prendido para otros tests
    render_click(view, "cambiar_agregacion_activa", %{"campo" => "meta_fixture_cliente_venta", "activo" => "false"})
    render_click(view, "cambiar_minmax_recomendado", %{"campo" => "meta_fixture_cliente_venta", "recomendado" => "false"})
    render_click(view, "cambiar_total_general", %{"campo" => "meta_fixture_cliente_venta", "activo" => "false"})
  end
end
