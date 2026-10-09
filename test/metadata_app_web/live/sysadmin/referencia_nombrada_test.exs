defmodule MetadataAppWeb.Sysadmin.ReferenciaNombradaTest do
  # SPEC-SYS-0510202601 §1 (R1-R4): nombre y etiqueta opcionales al agregar
  # un campo referencia, en "+ Agregar campo" (BcMotorLive) y en "Nuevo
  # catálogo" (BcNuevoCompletoLive).
  use MetadataAppWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import MetadataApp.AutenticacionFixtures

  alias MetadataApp.Repo
  alias MetadataApp.Autenticacion.{Empresa, Rol, UsuarioEmpresa}
  alias MetadataApp.BusinessProcessBuilder.MetaSchemaContext

  setup %{conn: conn} do
    usuario = usuario_fixture()

    {:ok, empresa} =
      %Empresa{} |> Empresa.changeset(%{nombre: "Empresa referencia test #{System.unique_integer()}"}) |> Repo.insert()

    {:ok, _} =
      %UsuarioEmpresa{} |> UsuarioEmpresa.changeset(%{usuario_id: usuario.id, empresa_id: empresa.id}) |> Repo.insert()

    rol_admin = Repo.get_by!(Rol, nombre: "administrador")
    {:ok, _} = MetadataApp.Permissions.asignar_rol(usuario.id, rol_admin.id, empresa.id)

    conn = conn |> log_in_usuario(usuario) |> Plug.Conn.put_session(:empresa_activa_id, empresa.id)

    s = System.unique_integer([:positive])
    destino = crear_header("pty_unidades#{s}", "/rn#{s}/unidades", "Unidades #{s}")
    editado = crear_header("pty_editado#{s}", "/rn#{s}/editado", "Editado #{s}")

    %{conn: conn, s: s, destino: destino, editado: editado}
  end

  defp crear_header(nombre, nav, etiqueta) do
    {:ok, {header, _}} =
      MetaSchemaContext.crear_header_con_detalles(%{
        "schema_context_name" => nombre,
        "schema_context_label" => etiqueta,
        "schema_context_nav" => nav,
        "schema_visible" => true,
        "schema_context_type" => 1,
        "detalles" => []
      })

    header
  end

  describe "BC Motor → + Agregar campo → Referencia" do
    test "muestra nombre y etiqueta opcionales con lo de siempre como sugerencia (R1-R3)", %{conn: conn, editado: editado, destino: destino} do
      {:ok, view, _html} = live(conn, ~p"/sysadmin/bc-list/#{editado.schema_context_name}/motor")
      render_click(view, "abrir_form_campo", %{})
      render_click(view, "asistente_elegir_tipo", %{"tipo" => "referencia"})

      view
      |> element("form[phx-change='asistente_cambiar']")
      |> render_change(%{"modulo" => "", "catalogo" => destino.schema_context_name})

      sufijo = String.replace_prefix(destino.schema_context_name, "pty_", "")
      assert has_element?(view, "#asistente-referencia-nombre[placeholder='#{sufijo}']")
      assert has_element?(view, "#asistente-referencia-etiqueta[placeholder='#{destino.schema_context_label}']")
    end
  end

  describe "Nuevo catálogo → Agregar campo → Referencia" do
    setup %{conn: conn, s: s} do
      {:ok, view, _html} = live(conn, ~p"/sysadmin/bc-list/nuevo-completo")
      view |> element("form[phx-change='validar_contexto']") |> render_change(%{"contexto" => %{"nombre" => "material#{s}"}})
      %{view: view, nombre_base: "pty_material#{s}"}
    end

    defp agregar_referencia(view, destino, nombre, etiqueta) do
      render_click(view, "abrir_form_campo", %{})
      view |> element("form[phx-change='validar_campo']") |> render_change(%{"tipo" => "referencia"})

      view
      |> element("form[phx-submit='guardar_campo']")
      |> render_submit(%{"tipo" => "referencia", "modulo" => "", "catalogo" => destino.schema_context_name, "nombre" => nombre, "etiqueta" => etiqueta})
    end

    test "dos referencias al mismo destino con nombres distintos se aceptan (R4)", %{view: view, destino: destino, nombre_base: base} do
      agregar_referencia(view, destino, "unidad_base", "Unidad base")
      html = agregar_referencia(view, destino, "unidad_venta", "Unidad de venta")

      refute has_element?(view, "form[phx-submit='guardar_campo']")
      assert html =~ "#{base}_unidad_base"
      assert html =~ "#{base}_unidad_venta"
      assert html =~ "Unidad de venta"
    end

    test "sin nombre usa el de siempre (R2)", %{view: view, destino: destino, nombre_base: base} do
      html = agregar_referencia(view, destino, "", "")

      sufijo = String.replace_prefix(destino.schema_context_name, "pty_", "")
      assert html =~ "#{base}_#{sufijo}"
      assert html =~ destino.schema_context_label
    end

    test "el mismo nombre dos veces se rechaza (R4)", %{view: view, destino: destino} do
      agregar_referencia(view, destino, "unidad_base", "")
      html = agregar_referencia(view, destino, "unidad_base", "")

      assert has_element?(view, "form[phx-submit='guardar_campo']")
      assert html =~ "Ya hay un campo con ese nombre."
    end

    test "dos referencias al mismo destino con la etiqueta vacía se rechazan (R4.1)", %{view: view, destino: destino} do
      agregar_referencia(view, destino, "unidad_base", "")
      html = agregar_referencia(view, destino, "unidad_venta", "")

      assert has_element?(view, "form[phx-submit='guardar_campo']")
      assert html =~ "Ya hay un campo con esa etiqueta."
    end

    test "un nombre inválido se rechaza (R1)", %{view: view, destino: destino} do
      html = agregar_referencia(view, destino, "Unidad Base", "")

      assert has_element?(view, "form[phx-submit='guardar_campo']")
      assert html =~ "Nombre inválido"
    end
  end
end
