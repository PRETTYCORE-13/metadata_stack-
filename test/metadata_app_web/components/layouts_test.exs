defmodule MetadataAppWeb.LayoutsTest do
  @moduledoc """
  Título de la pestaña del navegador (SPEC-SYS-0909202601 R23–R26): el
  nombre de la empresa activa, o "Prettycore" sin sesión.
  """
  use MetadataAppWeb.ConnCase, async: true

  import MetadataApp.AutenticacionFixtures

  alias MetadataApp.Autenticacion
  alias MetadataApp.Autenticacion.Scope
  alias MetadataAppWeb.Layouts

  # Texto del <title> (HTML inicial) y su data-default, que es lo que el
  # cliente de LiveView pone al montar si la pantalla no asigna
  # page_title. Los dos deben ser el mismo título.
  defp titulo(html) do
    title = html |> LazyHTML.from_document() |> LazyHTML.query("title")
    texto = title |> LazyHTML.text() |> String.trim()
    assert LazyHTML.attribute(title, "data-default") == [texto]
    texto
  end

  describe "titulo_pestana/1" do
    test "con empresa activa devuelve su nombre" do
      scope = %Scope{empresa_activa: %{nombre: "TABATA - Unstable System"}}
      assert Layouts.titulo_pestana(scope) == "TABATA - Unstable System"
    end

    test "sin scope o sin empresa activa devuelve Prettycore" do
      assert Layouts.titulo_pestana(nil) == "Prettycore"
      assert Layouts.titulo_pestana(%Scope{empresa_activa: nil}) == "Prettycore"
    end
  end

  test "con sesión, el título es exactamente el nombre de la empresa activa", %{conn: conn} do
    usuario = usuario_fixture()
    nombre = "Empresa pestaña #{System.unique_integer([:positive])}"
    {:ok, empresa} = Autenticacion.crear_empresa_para_usuario(nombre, usuario.id)

    html =
      conn
      |> log_in_usuario(usuario)
      |> Plug.Conn.put_session(:empresa_activa_id, empresa.id)
      |> get(~p"/")
      |> html_response(200)

    assert titulo(html) == nombre
  end

  test "al cambiar de empresa activa, el título pasa a la nueva empresa", %{conn: conn} do
    usuario = usuario_fixture()

    {:ok, origen} =
      Autenticacion.crear_empresa_para_usuario(
        "Origen #{System.unique_integer([:positive])}",
        usuario.id
      )

    {:ok, destino} =
      Autenticacion.crear_empresa_para_usuario(
        "Destino #{System.unique_integer([:positive])}",
        usuario.id
      )

    conn =
      conn
      |> log_in_usuario(usuario)
      |> Plug.Conn.put_session(:empresa_activa_id, origen.id)
      |> post(~p"/meta_schema_usuario/empresa/#{destino.id}/activar")

    html = conn |> recycle() |> get(redirected_to(conn)) |> html_response(200)

    assert titulo(html) == destino.nombre
  end

  test "sin sesión, el título es Prettycore", %{conn: conn} do
    html = conn |> get(~p"/meta_schema_usuario/log-in") |> html_response(200)

    assert titulo(html) == "Prettycore"
  end
end
