defmodule MetadataAppWeb.Sysadmin.BcListLivePrefijoDirectorioTest do
  # SPEC-SYS-2909202601 (Prefijo de directorio), Grupo B: R1, R3, R5, R8, R9.
  use MetadataAppWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias MetadataApp.Repo
  alias MetadataApp.Autenticacion.{Empresa, Rol, UsuarioEmpresa}
  alias MetadataApp.BusinessProcessBuilder.MetaSchemaContext

  import MetadataApp.AutenticacionFixtures

  setup %{conn: conn} do
    usuario = usuario_fixture()

    {:ok, empresa} =
      %Empresa{} |> Empresa.changeset(%{nombre: "Empresa prefijo test #{System.unique_integer()}"}) |> Repo.insert()

    {:ok, _} =
      %UsuarioEmpresa{} |> UsuarioEmpresa.changeset(%{usuario_id: usuario.id, empresa_id: empresa.id}) |> Repo.insert()

    rol_admin = Repo.get_by!(Rol, nombre: "administrador")
    {:ok, _} = MetadataApp.Permissions.asignar_rol(usuario.id, rol_admin.id, empresa.id)

    conn = conn |> log_in_usuario(usuario) |> Plug.Conn.put_session(:empresa_activa_id, empresa.id)
    %{conn: conn}
  end

  defp unique, do: System.unique_integer([:positive])

  defp crear_carpeta(etiqueta, prefijo) do
    sufijo = unique()

    {:ok, {header, _}} =
      MetaSchemaContext.crear_header_con_detalles(%{
        "schema_context_name" => "pty_carpeta_pd#{sufijo}",
        "schema_context_label" => etiqueta,
        "schema_context_nav" => "/pd#{sufijo}",
        "schema_visible" => true,
        "schema_context_type" => 2,
        "prefijo_directorio" => prefijo,
        "detalles" => []
      })

    header
  end

  defp params_nueva(slug, prefijo) do
    %{
      "contexto" => %{
        "etiqueta" => "Carpeta #{slug}",
        "carpeta_padre" => "",
        "nav_final" => slug,
        "prefijo" => prefijo,
        "icono" => "",
        "visible" => "true"
      }
    }
  end

  defp abrir_nueva(conn) do
    {:ok, view, _html} = live(conn, ~p"/sysadmin/bc-list")
    view |> element("#btn-nuevo-contexto") |> render_click()
    view
  end

  defp abrir_editar(conn, header) do
    {:ok, view, _html} = live(conn, ~p"/sysadmin/bc-list")
    render_click(view, "abrir_editar_carpeta", %{"nombre" => header.schema_context_name})
    view
  end

  describe "Nueva carpeta" do
    test "muestra el campo Prefijo", %{conn: conn} do
      view = abrir_nueva(conn)

      assert has_element?(view, "#form-nueva-carpeta #prefijo-nueva-carpeta[name='contexto[prefijo]'][maxlength='5']")
    end

    test "guarda el prefijo normalizado (R3)", %{conn: conn} do
      slug = "pdn#{unique()}"
      view = abrir_nueva(conn)

      view |> form("#form-nueva-carpeta", params_nueva(slug, "cá1")) |> render_submit()

      header = MetaSchemaContext.obtener_header_por_nav("/#{slug}")
      assert header.prefijo_directorio == "CA1"
    end

    test "sin prefijo no guarda (R1) y conserva 'Es visible' marcado", %{conn: conn} do
      slug = "pdv#{unique()}"
      view = abrir_nueva(conn)

      html = view |> form("#form-nueva-carpeta", params_nueva(slug, "")) |> render_submit()

      assert html =~ "El prefijo es obligatorio"
      assert MetaSchemaContext.obtener_header_por_nav("/#{slug}") == nil
      assert has_element?(view, "#form-nueva-carpeta input[type='checkbox'][name='contexto[visible]'][checked]")
    end

    test "prefijo repetido avisa en vivo con la etiqueta del otro directorio y no guarda (R5)", %{conn: conn} do
      crear_carpeta("Capital Humano Prueba", "DUP")
      slug = "pdd#{unique()}"
      view = abrir_nueva(conn)

      html = view |> form("#form-nueva-carpeta", params_nueva(slug, "dup")) |> render_change()
      assert html =~ "ya lo usa &#39;Capital Humano Prueba&#39;"

      view |> form("#form-nueva-carpeta", params_nueva(slug, "DUP")) |> render_submit()
      assert MetaSchemaContext.obtener_header_por_nav("/#{slug}") == nil
    end
  end

  describe "columna Prefijo (R11)" do
    test "carpeta con prefijo lo muestra; sin prefijo muestra 'Sin prefijo'; un catálogo no muestra nada", %{conn: conn} do
      con = crear_carpeta("Columna con", "COL")
      sin = crear_carpeta("Columna sin", nil)

      sufijo = unique()

      {:ok, {catalogo, _}} =
        MetaSchemaContext.crear_header_con_detalles(%{
          "schema_context_name" => "pty_catalogo_pd#{sufijo}",
          "schema_context_label" => "Catálogo columna",
          "schema_context_nav" => "/#{con.schema_context_nav |> String.trim_leading("/")}/cat#{sufijo}",
          "schema_visible" => true,
          "schema_context_type" => 1,
          "detalles" => []
        })

      {:ok, view, _html} = live(conn, ~p"/sysadmin/bc-list")

      assert view |> element("#prefijo-#{con.schema_context_name}") |> render() =~ "COL"
      assert has_element?(view, "#sin-prefijo-#{sin.schema_context_name}")
      refute has_element?(view, "#sin-prefijo-#{con.schema_context_name}")

      render_click(view, "toggle_carpeta", %{"ruta" => String.trim_leading(con.schema_context_nav, "/")})
      assert render(view) =~ catalogo.schema_context_name
      refute has_element?(view, "#prefijo-#{catalogo.schema_context_name}")
      refute has_element?(view, "#sin-prefijo-#{catalogo.schema_context_name}")
    end
  end

  describe "Editar carpeta" do
    test "muestra el prefijo actual", %{conn: conn} do
      header = crear_carpeta("Con prefijo", "VTA")
      view = abrir_editar(conn, header)

      assert has_element?(view, "#form-editar-carpeta #prefijo-editar-carpeta[value='VTA']")
    end

    test "conservar el propio prefijo guarda (R8)", %{conn: conn} do
      header = crear_carpeta("Nombre viejo", "KEEP")
      view = abrir_editar(conn, header)

      view
      |> form("#form-editar-carpeta", %{"contexto" => %{"etiqueta" => "Nombre nuevo", "prefijo" => "KEEP", "visible" => "true"}})
      |> render_submit()

      actualizado = MetaSchemaContext.obtener_header_por_nombre(header.schema_context_name)
      assert actualizado.schema_context_label == "Nombre nuevo"
      assert actualizado.prefijo_directorio == "KEEP"
    end

    test "cambiar a un prefijo de otro directorio no guarda (R5, R8)", %{conn: conn} do
      crear_carpeta("Dueño del prefijo", "OCUP")
      header = crear_carpeta("La que se edita", "LIBR")
      view = abrir_editar(conn, header)

      html =
        view
        |> form("#form-editar-carpeta", %{"contexto" => %{"etiqueta" => "La que se edita", "prefijo" => "OCUP", "visible" => "true"}})
        |> render_submit()

      assert html =~ "ya lo usa &#39;Dueño del prefijo&#39;"
      assert MetaSchemaContext.obtener_header_por_nombre(header.schema_context_name).prefijo_directorio == "LIBR"
    end

    test "directorio viejo sin prefijo no guarda hasta llenarlo (R9)", %{conn: conn} do
      header = crear_carpeta("Viejo", nil)
      view = abrir_editar(conn, header)

      view
      |> form("#form-editar-carpeta", %{"contexto" => %{"etiqueta" => "Viejo editado", "prefijo" => "", "visible" => "true"}})
      |> render_submit()

      assert MetaSchemaContext.obtener_header_por_nombre(header.schema_context_name).schema_context_label == "Viejo"

      view
      |> form("#form-editar-carpeta", %{"contexto" => %{"etiqueta" => "Viejo editado", "prefijo" => "OLD", "visible" => "true"}})
      |> render_submit()

      actualizado = MetaSchemaContext.obtener_header_por_nombre(header.schema_context_name)
      assert actualizado.schema_context_label == "Viejo editado"
      assert actualizado.prefijo_directorio == "OLD"
    end
  end
end
