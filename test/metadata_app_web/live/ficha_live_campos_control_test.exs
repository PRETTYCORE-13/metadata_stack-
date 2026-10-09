defmodule MetadataAppWeb.FichaLiveCamposControlTest do
  @moduledoc """
  SPEC-SYS-1109202607 (R6b): una plantilla publicada con campos de control
  (Folio, Estado, Creado por) no truena la Ficha en modo alta, donde
  todavía no hay registro: se muestran sin valor.
  """
  use MetadataAppWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import MetadataApp.AutenticacionFixtures

  alias MetadataApp.{MetaPlantillas, Permissions, Repo}
  alias MetadataApp.Autenticacion.{Empresa, Rol, UsuarioEmpresa}
  alias MetadataApp.BusinessProcessBuilder.MetaSchema.Header

  setup %{conn: conn} do
    usuario = usuario_fixture()
    {:ok, empresa} = %Empresa{} |> Empresa.changeset(%{nombre: "Empresa control #{System.unique_integer()}"}) |> Repo.insert()
    {:ok, _} = %UsuarioEmpresa{} |> UsuarioEmpresa.changeset(%{usuario_id: usuario.id, empresa_id: empresa.id}) |> Repo.insert()
    {:ok, _} = Permissions.asignar_rol(usuario.id, Repo.get_by!(Rol, nombre: "administrador").id, empresa.id)

    header = Repo.get_by!(Header, schema_context_name: "meta_fixture_cliente")

    definicion =
      ~w(folio estado creado_por)
      |> Enum.with_index()
      |> Enum.reduce(
        %{"tipo" => "raiz", "propiedades" => %{"filas" => 3, "columnas" => 1, "gap" => "normal"}, "hijos" => []},
        fn {clave, fila}, acc ->
          nodo = MetaPlantillas.nuevo_nodo_campo("string") |> put_in(["propiedades", "campo"], clave)
          {:ok, acc} = MetaPlantillas.colocar_en_celda(acc, nil, nodo, fila, 0)
          acc
        end
      )

    {:ok, plantilla} =
      MetaPlantillas.crear_plantilla(header.id, %{"nombre" => "Control", "estado" => "borrador", "definicion" => definicion})

    {:ok, _} = MetaPlantillas.publicar_plantilla(plantilla)

    conn = conn |> log_in_usuario(usuario) |> Plug.Conn.put_session(:empresa_activa_id, empresa.id)
    %{conn: conn}
  end

  test "el alta muestra Folio, Estado y Creado por sin valor", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/registro/meta_fixture_cliente/nuevo")

    for etiqueta <- ["Folio", "Estado", "Creado por"] do
      assert html =~ etiqueta
    end
  end
end
