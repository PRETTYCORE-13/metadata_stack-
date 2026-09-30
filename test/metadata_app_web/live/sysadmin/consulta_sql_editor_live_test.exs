defmodule MetadataAppWeb.Sysadmin.ConsultaSqlEditorLiveTest do
  @moduledoc "SPEC-SYS-2509202601 Grupos C-D: alta desde BC List, editor y BC autorizados."
  use MetadataAppWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Ecto.Query, only: [from: 2]
  import MetadataApp.AutenticacionFixtures

  alias MetadataApp.{Repo, ConsultasSql}
  alias MetadataApp.Autenticacion.{Empresa, Rol, UsuarioEmpresa}
  alias MetadataApp.BusinessProcessBuilder.MetaSchemaContext
  alias MetadataApp.BusinessProcessBuilder.MetaSchema.{Header, Detail}

  @sql_ok "SELECT id, branch_name AS descripcion FROM meta_schema_branch"

  setup %{conn: conn} do
    usuario = usuario_fixture()

    {:ok, empresa} =
      %Empresa{}
      |> Empresa.changeset(%{nombre: "Empresa sql view #{System.unique_integer()}"})
      |> Repo.insert()

    {:ok, _} =
      %UsuarioEmpresa{}
      |> UsuarioEmpresa.changeset(%{usuario_id: usuario.id, empresa_id: empresa.id})
      |> Repo.insert()

    rol_admin = Repo.get_by!(Rol, nombre: "administrador")
    {:ok, _} = MetadataApp.Permissions.asignar_rol(usuario.id, rol_admin.id, empresa.id)

    %{
      conn:
        conn |> log_in_usuario(usuario) |> Plug.Conn.put_session(:empresa_activa_id, empresa.id)
    }
  end

  defp crear_sql_view(uso \\ "diccionario") do
    {:ok, {header, _}} =
      ConsultasSql.crear(%{
        "etiqueta" => "Rutas test",
        "nav" => "/rutas_test_#{System.unique_integer([:positive])}",
        "uso" => uso
      })

    header.schema_context_name
  end

  defp editor(conn, nombre) do
    {:ok, view, _html} = live(conn, ~p"/sysadmin/bc-list/#{nombre}/consulta-sql")
    view
  end

  # Marca un campo real del fixture como usuario del Diccionario (solo metadata).
  defp usar_en_campo(nombre) do
    header = Repo.get_by!(Header, schema_context_name: "meta_fixture_cliente")

    detalle =
      Repo.get_by!(Detail,
        meta_schema_header_id: header.id,
        schema_context_field: "meta_fixture_cliente_edad"
      )

    props =
      Map.put(detalle.schema_context_properties, "diccionario", %{
        "consulta" => nombre,
        "descripcion" => ["descripcion"]
      })

    detalle |> Ecto.Changeset.change(%{schema_context_properties: props}) |> Repo.update!()
  end

  describe "BC List" do
    test "\"+ SQL View\" crea la SQL View y abre su editor", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/sysadmin/bc-list")
      # Guardar navega fuera de BC Lista y eso mata la revisión "listo para
      # publicarse" (start_async) si sigue corriendo; bajo el Sandbox,
      # matarla a mitad de una consulta tira la conexión que comparte este
      # test (SPEC-SYS-2809202601, 02.design.md D2).
      render_async(view, 5_000)
      view |> element("#btn-nueva-sql-view") |> render_click()
      assert has_element?(view, "#form-sql-view")

      slug = "sqlview-#{System.unique_integer([:positive])}"

      assert {:error, {:live_redirect, %{to: destino}}} =
               view
               |> form("#form-sql-view", %{
                 "contexto" => %{
                   "etiqueta" => "Rutas preventa",
                   "carpeta_padre" => "",
                   "nav_final" => slug,
                   "uso" => "consulta"
                 }
               })
               |> render_submit()

      nombre = ConsultasSql.nombre_desde_nav("/" <> slug)
      assert destino == "/sysadmin/bc-list/#{nombre}/consulta-sql"

      assert %{schema_context_type: 4, schema_visible: false} =
               MetaSchemaContext.obtener_header_por_nombre(nombre)

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

      assert [%{catalogo: "meta_fixture_cliente", campo: "meta_fixture_cliente_edad"}] =
               ConsultasSql.campos_que_usan(nombre)

      assert ConsultasSql.columnas_en_uso(nombre) == ["id", "descripcion"]
    end
  end

  describe "uso Servicio (SPEC-SYS-2509202601 P1-P4)" do
    @sql_servicio "SELECT t.id, t.nombre FROM (VALUES (1, 'uno'), (2, 'dos')) AS t(id, nombre) WHERE t.id = ANY(:ids)"

    defp guardar_servicio(view) do
      view |> element("#agregar-parametro") |> render_click()

      view
      |> form("#form-sql", %{
        "sql" => @sql_servicio,
        "parametros" => %{
          "0" => %{
            "nombre" => "ids",
            "tipo" => "lista_enteros",
            "obligatorio" => "true",
            "default" => ""
          }
        },
        "tope_renglones" => "50"
      })
      |> render_submit()
    end

    test "P1: el alta en BC List ofrece Servicio y lo crea", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/sysadmin/bc-list")
      render_async(view, 5_000)
      view |> element("#btn-nueva-sql-view") |> render_click()
      assert has_element?(view, "#uso-servicio")

      slug = "svc-#{System.unique_integer([:positive])}"

      assert {:error, {:live_redirect, %{to: _destino}}} =
               view
               |> form("#form-sql-view", %{
                 "contexto" => %{
                   "etiqueta" => "Precio",
                   "carpeta_padre" => "",
                   "nav_final" => slug,
                   "uso" => "servicio"
                 }
               })
               |> render_submit()

      assert %{uso: "servicio"} =
               ConsultasSql.obtener_por_catalogo(ConsultasSql.nombre_desde_nav("/#{slug}"))
    end

    test "P2: uso fijo, parámetros, tope y guardar crean la función", %{conn: conn} do
      nombre = crear_sql_view("servicio")
      view = editor(conn, nombre)

      assert has_element?(view, "#uso-servicio-fijo")
      refute has_element?(view, "#form-uso")
      refute has_element?(view, "#bc-autorizados")

      guardar_servicio(view)

      guardado = ConsultasSql.obtener_por_catalogo(nombre)

      assert [%{"nombre" => "ids", "tipo" => "lista_enteros", "obligatorio" => true}] =
               guardado.parametros

      assert guardado.tope_renglones == 50
      assert has_element?(view, "#columnas-detectadas", "nombre")
      assert has_element?(view, "#parametro-0")
      refute has_element?(view, "#vista-previa")
    end

    test "P2: un parámetro no declarado muestra el error y no guarda", %{conn: conn} do
      nombre = crear_sql_view("servicio")
      view = editor(conn, nombre)

      view |> form("#form-sql", %{"sql" => "SELECT :otro AS x"}) |> render_submit()

      assert has_element?(view, "#sql-error", "no están declarados")
      assert ConsultasSql.obtener_por_catalogo(nombre).sql == nil
    end

    test "P2: quitar un parámetro", %{conn: conn} do
      view = editor(conn, crear_sql_view("servicio"))
      view |> element("#agregar-parametro") |> render_click()
      assert has_element?(view, "#parametro-0")
      view |> element("#quitar-parametro-0") |> render_click()
      refute has_element?(view, "#parametro-0")
    end

    test "P3: Probar muestra las filas o el error", %{conn: conn} do
      nombre = crear_sql_view("servicio")
      view = editor(conn, nombre)
      guardar_servicio(view)

      view |> form("#form-probar", %{"valores" => %{"ids" => "2"}}) |> render_submit()
      assert has_element?(view, "#prueba-resultado", "dos")
      refute has_element?(view, "#prueba-resultado", "uno")

      view |> form("#form-probar", %{"valores" => %{"ids" => ""}}) |> render_submit()
      assert has_element?(view, "#prueba-error", "Falta el parámetro obligatorio «ids»")
    end

    test "P4: el Contrato documenta la llamada desde una regla, parámetros y Endpoint", %{
      conn: conn
    } do
      nombre = crear_sql_view("servicio")
      view = editor(conn, nombre)
      guardar_servicio(view)

      view |> element("#tab-contrato") |> render_click()
      assert has_element?(view, "#contrato-regla", "MetaBcApi.ejecutar_servicio")
      assert has_element?(view, "#contrato-parametros", "ids")
      assert has_element?(view, "#contrato-endpoint", "Sin Endpoint todavía")

      empresa_id = Repo.one!(from(e in Empresa, select: max(e.id)))

      {:ok, _} =
        MetadataApp.ConsultaEndpoints.crear_o_actualizar(
          ConsultasSql.obtener_por_catalogo(nombre),
          %{
            "nombre" => "Precio",
            "metodo" => "post",
            "ruta" => "p4-#{System.unique_integer([:positive])}",
            "empresa_id" => empresa_id
          }
        )

      view = editor(conn, nombre)
      view |> element("#tab-contrato") |> render_click()
      assert has_element?(view, "#contrato-ruta-endpoint", "/api/consultas/p4-")
    end

    test "P5: crear, publicar, credencial (llave una vez), revocar y eliminar el Endpoint desde el Contrato",
         %{conn: conn} do
      nombre = crear_sql_view("servicio")
      view = editor(conn, nombre)
      guardar_servicio(view)
      view |> element("#tab-contrato") |> render_click()

      ruta = "p5-#{System.unique_integer([:positive])}"

      view
      |> form("#form-endpoint", %{"endpoint" => %{"nombre" => "Precio", "ruta" => ruta}})
      |> render_submit()

      servicio = ConsultasSql.obtener_por_catalogo(nombre)
      endpoint = ConsultasSql.endpoint_del_servicio(servicio)
      assert endpoint.ruta == ruta and endpoint.estado == "borrador"
      assert has_element?(view, "#contrato-ruta-endpoint", ruta)
      assert has_element?(view, "#aviso-borrador")

      view |> element("#publicar-endpoint") |> render_click()
      assert ConsultasSql.endpoint_del_servicio(servicio).estado == "publicado"
      assert has_element?(view, "#despublicar-endpoint")
      refute has_element?(view, "#aviso-borrador")

      view
      |> form("#form-credencial", %{"credencial" => %{"nombre" => "App", "campos" => ["id"]}})
      |> render_submit()

      assert has_element?(view, "#key-temporal")
      [credencial] = MetadataApp.ConsultaEndpoints.listar_credenciales(endpoint.id)
      assert credencial.campos_permitidos == ["id"]

      view |> element("#revocar-#{credencial.id}") |> render_click()

      assert [%{estado: "revocada"}] =
               MetadataApp.ConsultaEndpoints.listar_credenciales(endpoint.id)

      view |> element("#eliminar-endpoint") |> render_click()
      assert ConsultasSql.endpoint_del_servicio(servicio) == nil
      assert ConsultasSql.obtener_por_catalogo(nombre)
      assert has_element?(view, "#form-endpoint")
    end

    test "P5: una ruta inválida muestra el error", %{conn: conn} do
      nombre = crear_sql_view("servicio")
      view = editor(conn, nombre)
      guardar_servicio(view)
      view |> element("#tab-contrato") |> render_click()

      view
      |> form("#form-endpoint", %{
        "endpoint" => %{"nombre" => "Precio", "ruta" => "Ruta Con Espacios"}
      })
      |> render_submit()

      assert has_element?(view, "#endpoint-error", "ruta")
    end

    test "Diccionario y Consulta siguen igual: sin parámetros ni Probar (R58)", %{conn: conn} do
      view = editor(conn, crear_sql_view("diccionario"))
      assert has_element?(view, "#form-uso")
      refute has_element?(view, "#parametros-servicio")
      refute has_element?(view, "#probar-servicio")
    end
  end
end
