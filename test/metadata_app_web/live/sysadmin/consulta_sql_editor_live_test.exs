defmodule MetadataAppWeb.Sysadmin.ConsultaSqlEditorLiveTest do
  @moduledoc "SPEC-SYS-2509202601 Grupos C-D: alta desde BC List, editor y BC autorizados."
  use MetadataAppWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import MetadataApp.AutenticacionFixtures

  alias MetadataApp.{Repo, ConsultasSql}
  alias MetadataApp.Autenticacion.{Empresa, Rol, UsuarioEmpresa}
  alias MetadataApp.BusinessProcessBuilder.MetaSchemaContext
  alias MetadataApp.BusinessProcessBuilder.MetaSchema.{Header, Detail}

  @sql_ok "SELECT id, branch_name AS descripcion FROM meta_schema_branch"

  setup %{conn: conn} do
    usuario = usuario_fixture()
    {:ok, empresa} = %Empresa{} |> Empresa.changeset(%{nombre: "Empresa sql view #{System.unique_integer()}"}) |> Repo.insert()
    {:ok, _} = %UsuarioEmpresa{} |> UsuarioEmpresa.changeset(%{usuario_id: usuario.id, empresa_id: empresa.id}) |> Repo.insert()
    rol_admin = Repo.get_by!(Rol, nombre: "administrador")
    {:ok, _} = MetadataApp.Permissions.asignar_rol(usuario.id, rol_admin.id, empresa.id)

    %{conn: conn |> log_in_usuario(usuario) |> Plug.Conn.put_session(:empresa_activa_id, empresa.id)}
  end

  defp crear_sql_view(uso \\ "diccionario") do
    {:ok, {header, _}} = ConsultasSql.crear(%{"etiqueta" => "Rutas test", "nav" => "/rutas_test_#{System.unique_integer([:positive])}", "uso" => uso})
    header.schema_context_name
  end

  defp editor(conn, nombre) do
    {:ok, view, _html} = live(conn, ~p"/sysadmin/bc-list/#{nombre}/consulta-sql")
    view
  end

  # Marca un campo real del fixture como usuario del Diccionario (solo metadata).
  defp usar_en_campo(nombre) do
    header = Repo.get_by!(Header, schema_context_name: "meta_fixture_cliente")
    detalle = Repo.get_by!(Detail, meta_schema_header_id: header.id, schema_context_field: "meta_fixture_cliente_edad")
    props = Map.put(detalle.schema_context_properties, "diccionario", %{"consulta" => nombre, "descripcion" => ["descripcion"]})
    detalle |> Ecto.Changeset.change(%{schema_context_properties: props}) |> Repo.update!()
  end

  describe "BC List" do
    test "\"+ SQL View\" crea la SQL View y abre su editor", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/sysadmin/bc-list")
      view |> element("#btn-nueva-sql-view") |> render_click()
      assert has_element?(view, "#form-sql-view")

      slug = "sqlview-#{System.unique_integer([:positive])}"

      assert {:error, {:live_redirect, %{to: destino}}} =
               view
               |> form("#form-sql-view", %{"contexto" => %{"etiqueta" => "Rutas preventa", "carpeta_padre" => "", "nav_final" => slug, "uso" => "consulta"}})
               |> render_submit()

      nombre = ConsultasSql.nombre_desde_nav("/" <> slug)
      assert destino == "/sysadmin/bc-list/#{nombre}/consulta-sql"
      assert %{schema_context_type: 4, schema_visible: false} = MetaSchemaContext.obtener_header_por_nombre(nombre)
      assert ConsultasSql.obtener_por_catalogo(nombre).uso == "consulta"
    end

    test "Eliminar quita la SQL View, y no se puede si un campo la usa", %{conn: conn} do
      libre = crear_sql_view()
      en_uso = crear_sql_view()
      usar_en_campo(en_uso)

      {:ok, view, _html} = live(conn, ~p"/sysadmin/bc-list")

      render_click(view, "pedir_eliminar_sql_view", %{"nombre" => en_uso, "label" => "x"})
      render_click(view, "confirmar_eliminar_sql_view", %{})
      assert MetaSchemaContext.obtener_header_por_nombre(en_uso)

      render_click(view, "pedir_eliminar_sql_view", %{"nombre" => libre, "label" => "x"})
      render_click(view, "confirmar_eliminar_sql_view", %{})
      refute MetaSchemaContext.obtener_header_por_nombre(libre)
    end
  end

  describe "editor" do
    test "tiene los tabs Configuración, Contrato y Permisos", %{conn: conn} do
      view = editor(conn, crear_sql_view())
      assert has_element?(view, "#tab-configuracion")
      assert has_element?(view, "#tab-contrato")
      assert has_element?(view, "#tab-permisos")
      refute has_element?(view, "#tab-get_config")

      view |> element("#tab-contrato") |> render_click()
      assert has_element?(view, "#contrato-ruta")
    end

    test "Permisos: solo lectura y alcance propio de una SQL View", %{conn: conn} do
      view = editor(conn, crear_sql_view())
      view |> element("#tab-permisos") |> render_click()

      html = render(view)
      assert html =~ "alcance-sql-view"
      refute html =~ "meta_schema_consulta"
    end

    test "guardar un SQL válido muestra columnas, vista previa y aviso de alcance", %{conn: conn} do
      nombre = crear_sql_view()
      view = editor(conn, nombre)

      view |> form("#form-sql", %{"sql" => @sql_ok}) |> render_submit()

      assert has_element?(view, "#columnas-detectadas")
      assert has_element?(view, "#vista-previa") or render(view) =~ "no regresa filas"
      assert has_element?(view, "#aviso-alcance")
      assert ConsultasSql.obtener_por_catalogo(nombre).sql == @sql_ok
    end

    test "un SQL inválido muestra el error y no guarda", %{conn: conn} do
      nombre = crear_sql_view()
      view = editor(conn, nombre)

      view |> form("#form-sql", %{"sql" => "DELETE FROM meta_schema_branch"}) |> render_submit()

      assert has_element?(view, "#sql-error")
      assert ConsultasSql.obtener_por_catalogo(nombre).sql == nil
    end

    test "cambiar a Consulta oculta la sección de BC autorizados", %{conn: conn} do
      view = editor(conn, crear_sql_view())
      assert has_element?(view, "#bc-autorizados")

      view |> form("#form-uso", %{"uso" => "consulta"}) |> render_change()
      refute has_element?(view, "#bc-autorizados")
    end

    test "R4: un Diccionario en uso no pasa a Consulta", %{conn: conn} do
      nombre = crear_sql_view()
      {:ok, _} = ConsultasSql.guardar_sql(nombre, @sql_ok)
      usar_en_campo(nombre)
      view = editor(conn, nombre)

      view |> form("#form-uso", %{"uso" => "consulta"}) |> render_change()
      assert has_element?(view, "#uso-error")
      assert ConsultasSql.obtener_por_catalogo(nombre).uso == "diccionario"
    end
  end

  describe "BC que pueden usarla" do
    test "autorizar y quitar; no se quita un BC con campos que la usan", %{conn: conn} do
      nombre = crear_sql_view()
      view = editor(conn, nombre)

      view |> form("#form-buscar-bc", %{"busqueda" => "meta_fixture_cliente"}) |> render_change()
      view |> element("#autorizar-meta_fixture_cliente") |> render_click()
      assert has_element?(view, "#autorizado-meta_fixture_cliente")
      assert "meta_fixture_cliente" in ConsultasSql.obtener_por_catalogo(nombre).bcs_autorizados

      usar_en_campo(nombre)
      view |> element("#autorizado-meta_fixture_cliente button", "Quitar") |> render_click()
      assert has_element?(view, "#bc-error")
      assert "meta_fixture_cliente" in ConsultasSql.obtener_por_catalogo(nombre).bcs_autorizados
    end

    test "campos_que_usan/1 reporta BC y campo" do
      nombre = crear_sql_view()
      usar_en_campo(nombre)

      assert [%{catalogo: "meta_fixture_cliente", campo: "meta_fixture_cliente_edad"}] = ConsultasSql.campos_que_usan(nombre)
      assert ConsultasSql.columnas_en_uso(nombre) == ["id", "descripcion"]
    end
  end
end
