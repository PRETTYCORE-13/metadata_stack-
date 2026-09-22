defmodule MetadataAppWeb.BusinessProcessBuilder.CatalogoAdminController do
  use MetadataAppWeb, :controller
  alias MetadataApp.BusinessProcessBuilder.CatalogoGenerador
  alias MetadataApp.MetaEstadosAdmin
  alias MetadataAppWeb.AuditoriaContexto

  # SPEC-SYS-2209202601 (R7-R8, design.md §3) -- recurso fijo, mismo
  # permiso de plataforma que ya protege BC Motor/BC List en la web.
  # `delete` es destructivo (borra el catálogo entero) -- nunca con un
  # permiso más débil que "editar la estructura" (R8).
  plug MetadataAppWeb.Plugs.RequierePermiso,
       [recurso: "sysadmin_bc", accion: "leer"] when action in [:impacto, :validar_motor, :completitud]

  plug MetadataAppWeb.Plugs.RequierePermiso, [recurso: "sysadmin_bc", accion: "editar"] when action in [:delete]

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

    with {:ok, resultado} <-
           CatalogoGenerador.eliminar(tabla, confirmar_tabla, confirmar_filas, AuditoriaContexto.desde_conn(conn)) do
      json(conn, resultado)
    end
  end
end
