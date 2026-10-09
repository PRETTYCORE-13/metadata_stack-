defmodule MetadataAppWeb.FichaLiveAlineacionCeldaTest do
  @moduledoc """
  SPEC-SYS-1109202607 §6e (R29): en una celda con un campo, la alineación
  horizontal mueve el bloque etiqueta + valor (fila flex), no solo el
  texto. Escenario: MetadataApp.PedidoMultinivelFixtures con el folio en
  una celda del formulario publicado.
  """
  # async: false -- registra la metadata de pedido_prueba_multinivel.
  use MetadataAppWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import MetadataApp.AutenticacionFixtures
  import MetadataApp.PedidoMultinivelFixtures

  alias MetadataApp.{MetaPlantillas, Permissions, Repo}
  alias MetadataApp.Autenticacion.{Empresa, Rol, UsuarioEmpresa}

  setup %{conn: conn} do
    usuario = usuario_fixture()
    {:ok, empresa} = %Empresa{} |> Empresa.changeset(%{nombre: "Empresa alineación #{System.unique_integer()}"}) |> Repo.insert()
    {:ok, _} = %UsuarioEmpresa{} |> UsuarioEmpresa.changeset(%{usuario_id: usuario.id, empresa_id: empresa.id}) |> Repo.insert()
    rol = Repo.get_by!(Rol, nombre: "administrador")
    {:ok, _} = Permissions.asignar_rol(usuario.id, rol.id, empresa.id)

    maestro = registrar_metadata!()
    Permissions.conceder_permisos_catalogo(rol.id, Enum.map(~w(leer crear editar alta guardar), &{maestro(), &1}))

    conn = conn |> log_in_usuario(usuario) |> Plug.Conn.put_session(:empresa_activa_id, empresa.id)
    %{conn: conn, maestro: maestro, pedido: pedido!("ALINEACION", ["Tornillos"])}
  end

  defp publicar_folio_alineado!(maestro, alineacion) do
    nodo = MetaPlantillas.nuevo_nodo("campo") |> put_in(["propiedades", "campo"], folio())
    raiz = %{"tipo" => "raiz", "propiedades" => %{"filas" => 1, "columnas" => 1, "gap" => "normal"}, "hijos" => []}
    {:ok, definicion} = MetaPlantillas.colocar_en_celda(raiz, nil, nodo, 0, 0)
    definicion = MetaPlantillas.actualizar_celda(definicion, nodo["id"], %{"alineacion_h" => alineacion})
    {:ok, plantilla} = MetaPlantillas.crear_plantilla(maestro.id, %{"nombre" => "Alineación", "estado" => "borrador", "definicion" => definicion})
    {:ok, _} = MetaPlantillas.publicar_plantilla(plantilla)
  end

  defp clases_fila_folio(conn, pedido) do
    {:ok, view, _} = live(conn, "/registro/#{maestro()}/#{pedido.id}")

    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(".text-right > div, .text-center > div, .text-left > div")
    |> LazyHTML.attribute("class")
    |> List.first()
  end

  test "Derecha mueve la fila del campo a la derecha", %{conn: conn, maestro: maestro, pedido: pedido} do
    publicar_folio_alineado!(maestro, "derecha")
    assert clases_fila_folio(conn, pedido) =~ "sm:justify-end"
  end

  test "Centro la centra", %{conn: conn, maestro: maestro, pedido: pedido} do
    publicar_folio_alineado!(maestro, "centro")
    assert clases_fila_folio(conn, pedido) =~ "sm:justify-center"
  end

  test "Izquierda la deja como siempre", %{conn: conn, maestro: maestro, pedido: pedido} do
    publicar_folio_alineado!(maestro, "izquierda")
    clases = clases_fila_folio(conn, pedido)
    refute clases =~ "justify-end"
    refute clases =~ "justify-center"
  end
end
