defmodule MetadataAppWeb.CatalogoAdminController do
  use MetadataAppWeb, :controller
  alias MetadataApp.CatalogoGenerador

  action_fallback MetadataAppWeb.FallbackController

  def impacto(conn, %{"tabla" => tabla}) do
    with {:ok, resultado} <- CatalogoGenerador.impacto(tabla) do
      json(conn, resultado)
    end
  end

  def delete(conn, %{"tabla" => tabla} = params) do
    confirmar_tabla = Map.get(params, "confirmar_tabla")

    with {:ok, resultado} <- CatalogoGenerador.eliminar(tabla, confirmar_tabla) do
      json(conn, resultado)
    end
  end
end
