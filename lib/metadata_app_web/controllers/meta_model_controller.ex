defmodule MetadataAppWeb.MetaModelController do
  use MetadataAppWeb, :controller
  alias MetadataApp.MetaModelContext

  action_fallback MetadataAppWeb.FallbackController

  def index(conn, %{"schema_nombre" => schema_nombre}) do
    campos = MetaModelContext.listar_campos(schema_nombre)
    render(conn, :index, campos: campos)
  end

  def show(conn, %{"id" => id}) do
    campo = MetaModelContext.obtener_campo!(id)
    render(conn, :show, campo: campo)
  end

  def create(conn, %{"meta_model" => campo_params}) do
    with {:ok, campo} <- MetaModelContext.crear_campo(campo_params) do
      conn
      |> put_status(:created)
      |> render(:show, campo: campo)
    end
  end

  def update(conn, %{"id" => id, "meta_model" => campo_params}) do
    campo = MetaModelContext.obtener_campo!(id)

    with {:ok, campo} <- MetaModelContext.actualizar_campo(campo, campo_params) do
      render(conn, :show, campo: campo)
    end
  end

  def delete(conn, %{"id" => id}) do
    campo = MetaModelContext.obtener_campo!(id)

    with {:ok, _campo} <- MetaModelContext.eliminar_campo(campo) do
      send_resp(conn, :no_content, "")
    end
  end
end
