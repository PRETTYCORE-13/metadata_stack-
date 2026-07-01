defmodule MetadataAppWeb.MarcaController do
  use MetadataAppWeb, :controller
  alias MetadataApp.Catalogos

  action_fallback MetadataAppWeb.FallbackController

  def index(conn, params) do
    marcas = Catalogos.listar_marcas(params)
    render(conn, :index, marcas: marcas)
  end

  def show(conn, %{"id" => id}) do
    marca = Catalogos.obtener_marca!(id)
    render(conn, :show, marca: marca)
  end

  def create(conn, %{"marca" => marca_params}) do
    with {:ok, marca} <- Catalogos.crear_marca(marca_params) do
      conn
      |> put_status(:created)
      |> render(:show, marca: marca)
    end
  end

  def update(conn, %{"id" => id, "marca" => marca_params}) do
    marca = Catalogos.obtener_marca!(id)

    with {:ok, marca} <- Catalogos.actualizar_marca(marca, marca_params) do
      render(conn, :show, marca: marca)
    end
  end

  def delete(conn, %{"id" => id}) do
    marca = Catalogos.obtener_marca!(id)

    with {:ok, _marca} <- Catalogos.eliminar_marca(marca) do
      send_resp(conn, :no_content, "")
    end
  end
end
