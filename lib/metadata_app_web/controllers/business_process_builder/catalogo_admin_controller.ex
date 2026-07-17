defmodule MetadataAppWeb.BusinessProcessBuilder.CatalogoAdminController do
  use MetadataAppWeb, :controller
  alias MetadataApp.BusinessProcessBuilder.CatalogoGenerador
  alias MetadataApp.MetaEstadosAdmin

  action_fallback MetadataAppWeb.FallbackController

  def impacto(conn, %{"tabla" => tabla}) do
    with {:ok, resultado} <- CatalogoGenerador.impacto(tabla) do
      json(conn, resultado)
    end
  end

  def validar_motor(conn, %{"tabla" => tabla}) do
    with {:ok, resultado} <- MetaEstadosAdmin.validar_motor(tabla) do
      json(conn, resultado)
    end
  end

  def completitud(conn, %{"tabla" => tabla}) do
    with {:ok, resultado} <- MetaEstadosAdmin.completitud(tabla) do
      json(conn, resultado)
    end
  end

  def delete(conn, %{"tabla" => tabla} = params) do
    confirmar_tabla = Map.get(params, "confirmar_tabla")
    confirmar_filas = Map.get(params, "confirmar_filas")

    with {:ok, resultado} <- CatalogoGenerador.eliminar(tabla, confirmar_tabla, confirmar_filas) do
      json(conn, resultado)
    end
  end
end
