defmodule MetadataAppWeb.Sysadmin.CatalogoDestinoPorModuloTest do
  # SPEC-SYS-1109202601 §2.3 (R35-R40): "Catálogo destino" filtrado por
  # módulo en "+ Agregar campo" (BcMotorLive) y en "Nuevo catálogo"
  # (BcNuevoCompletoLive).
  use MetadataAppWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import MetadataApp.AutenticacionFixtures

  alias MetadataApp.Repo
  alias MetadataApp.Autenticacion.{Empresa, Rol, UsuarioEmpresa}
  alias MetadataApp.BusinessProcessBuilder.MetaSchemaContext

  setup %{conn: conn} do
    usuario = usuario_fixture()

    {:ok, empresa} =
      %Empresa{} |> Empresa.changeset(%{nombre: "Empresa módulo test #{System.unique_integer()}"}) |> Repo.insert()

    {:ok, _} =
      %UsuarioEmpresa{} |> UsuarioEmpresa.changeset(%{usuario_id: usuario.id, empresa_id: empresa.id}) |> Repo.insert()

    rol_admin = Repo.get_by!(Rol, nombre: "administrador")
    {:ok, _} = MetadataApp.Permissions.asignar_rol(usuario.id, rol_admin.id, empresa.id)

    conn = conn |> log_in_usuario(usuario) |> Plug.Conn.put_session(:empresa_activa_id, empresa.id)

    s = System.unique_integer([:positive])
    crear_header("pty_carpeta_tma#{s}", 2, "/tma#{s}", "TMA", "Módulo A")
    crear_header("pty_carpeta_tmb#{s}", 2, "/tmb#{s}", "TMB", "Módulo B")
    cat_a = crear_header("pty_cat_a#{s}", 1, "/tma#{s}/cat-a", nil, "Catálogo A #{s}")
    cat_b = crear_header("pty_cat_b#{s}", 1, "/tmb#{s}/cat-b", nil, "Catálogo B #{s}")
    editado = crear_header("pty_editado#{s}", 1, "/tma#{s}/editado", nil, "Editado #{s}")

    %{conn: conn, s: s, cat_a: cat_a, cat_b: cat_b, editado: editado}
  end

  defp crear_header(nombre, tipo, nav, prefijo, etiqueta) do
    {:ok, {header, _}} =
      MetaSchemaContext.crear_header_con_detalles(%{
        "schema_context_name" => nombre,
        "schema_context_label" => etiqueta,
        "schema_context_nav" => nav,
        "schema_visible" => true,
        "schema_context_type" => tipo,
        "prefijo_directorio" => prefijo,
        "detalles" => []
      })

    header
  end

  defp opcion?(view, select, nombre), do: has_element?(view, "#{select} option[value='#{nombre}']")

  describe "BC Motor → + Agregar campo" do
    setup %{conn: conn, editado: editado} do
      {:ok, view, _html} = live(conn, ~p"/sysadmin/bc-list/#{editado.schema_context_name}/motor")
      render_click(view, "abrir_form_campo", %{})
      render_click(view, "asistente_elegir_tipo", %{"tipo" => "referencia"})
      %{view: view}
    end

    test "arranca en el módulo del BC y filtra (R35-R37)", %{view: view, cat_a: cat_a, cat_b: cat_b} do
      assert has_element?(view, "#asistente-modulo option[value='TMA'][selected]")
      assert opcion?(view, "#asistente-catalogo", cat_a.schema_context_name)
      refute opcion?(view, "#asistente-catalogo", cat_b.schema_context_name)
      assert opcion?(view, "#asistente-catalogo", "meta_schema_empresa")
    end

    test "\"Todos\" muestra todo (R39)", %{view: view, cat_a: cat_a, cat_b: cat_b} do
      view |> element("form[phx-change='asistente_cambiar']") |> render_change(%{"modulo" => "", "catalogo" => ""})

      assert opcion?(view, "#asistente-catalogo", cat_a.schema_context_name)
      assert opcion?(view, "#asistente-catalogo", cat_b.schema_context_name)
    end

    test "cambiar a un módulo donde no está el destino elegido lo quita (R38)", %{view: view, cat_a: cat_a} do
      formulario = element(view, "form[phx-change='asistente_cambiar']")

      render_change(formulario, %{"modulo" => "TMA", "catalogo" => cat_a.schema_context_name})
      assert has_element?(view, "#asistente-catalogo option[value='#{cat_a.schema_context_name}'][selected]")

      render_change(formulario, %{"modulo" => "TMB", "catalogo" => cat_a.schema_context_name})
      refute opcion?(view, "#asistente-catalogo", cat_a.schema_context_name)

      # De vuelta en "Todos" sin mandar "catalogo": si el servidor hubiera
      # conservado el destino oculto, aparecería seleccionado.
      render_change(formulario, %{"modulo" => ""})
      assert opcion?(view, "#asistente-catalogo", cat_a.schema_context_name)
      refute has_element?(view, "#asistente-catalogo option[value='#{cat_a.schema_context_name}'][selected]")
    end
  end

  describe "Nuevo catálogo → Agregar campo" do
    setup %{conn: conn, s: s} do
      {:ok, view, _html} = live(conn, ~p"/sysadmin/bc-list/nuevo-completo")
      view |> element("form[phx-change='validar_contexto']") |> render_change(%{"contexto" => %{"nombre" => "prueba#{s}", "carpeta_padre" => "tma#{s}"}})
      render_click(view, "abrir_form_campo", %{})
      view |> element("form[phx-change='validar_campo']") |> render_change(%{"tipo" => "referencia"})
      %{view: view}
    end

    test "arranca en el módulo de la carpeta de Navegación y filtra (R35-R37)", %{view: view, cat_a: cat_a, cat_b: cat_b} do
      assert has_element?(view, "#campo-modulo option[value='TMA'][selected]")
      assert opcion?(view, "#campo-catalogo", cat_a.schema_context_name)
      refute opcion?(view, "#campo-catalogo", cat_b.schema_context_name)
      assert opcion?(view, "#campo-catalogo", "meta_schema_empresa")
    end

    test "cambiar de módulo filtra y quita el destino que quedó fuera (R36, R38)", %{view: view, cat_a: cat_a, cat_b: cat_b} do
      formulario = element(view, "form[phx-change='validar_campo']")

      render_change(formulario, %{"tipo" => "referencia", "modulo" => "TMA", "catalogo" => cat_a.schema_context_name})
      assert has_element?(view, "#campo-catalogo option[value='#{cat_a.schema_context_name}'][selected]")

      render_change(formulario, %{"tipo" => "referencia", "modulo" => "TMB", "catalogo" => cat_a.schema_context_name})
      refute opcion?(view, "#campo-catalogo", cat_a.schema_context_name)
      assert opcion?(view, "#campo-catalogo", cat_b.schema_context_name)
      refute has_element?(view, "#campo-catalogo option[selected][value]:not([value=''])")
    end

    test "guardar un campo referencia sigue funcionando", %{view: view, cat_a: cat_a} do
      html =
        view
        |> element("form[phx-submit='guardar_campo']")
        |> render_submit(%{"tipo" => "referencia", "modulo" => "TMA", "catalogo" => cat_a.schema_context_name})

      refute has_element?(view, "form[phx-submit='guardar_campo']")
      assert html =~ cat_a.schema_context_label
    end
  end
end
