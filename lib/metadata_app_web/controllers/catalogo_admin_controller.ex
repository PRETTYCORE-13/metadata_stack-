defmodule MetadataAppWeb.CatalogoAdminController do
  use MetadataAppWeb, :controller
  alias MetadataApp.CatalogoGenerador
  alias MetadataApp.MotorEstadosAdmin

  action_fallback MetadataAppWeb.FallbackController

  def impacto(conn, %{"tabla" => tabla}) do
    with {:ok, resultado} <- CatalogoGenerador.impacto(tabla) do
      json(conn, resultado)
    end
  end

  def validar_motor(conn, %{"tabla" => tabla}) do
    with {:ok, resultado} <- MotorEstadosAdmin.validar_motor(tabla) do
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
