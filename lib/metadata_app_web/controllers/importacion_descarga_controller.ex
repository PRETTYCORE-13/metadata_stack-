defmodule MetadataAppWeb.ImportacionDescargaController do
  @moduledoc """
  Descarga de la plantilla Excel de una `PlantillaImportacion` — acción de
  controller (no LiveView) porque un socket no puede stream-ear un
  archivo al navegador; el nombre/definición vigente siempre se
  regeneran al vuelo desde la base, nunca un archivo cacheado en disco.
  """

  use MetadataAppWeb, :controller

  alias MetadataApp.MetaImportacionDatos

  plug MetadataAppWeb.Plugs.RequierePermiso, [recurso: "sysadmin_bc", accion: "editar"]

  action_fallback MetadataAppWeb.FallbackController

  def descargar(conn, %{"plantilla_id" => plantilla_id}) do
    plantilla = MetaImportacionDatos.obtener_plantilla!(plantilla_id)

    case MetaImportacionDatos.generar_excel(plantilla) do
      {:ok, binario} ->
        nombre_archivo = "#{nombre_archivo_seguro(plantilla.nombre)}.xlsx"

        conn
        |> put_resp_content_type("application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")
        |> put_resp_header("content-disposition", ~s(attachment; filename="#{nombre_archivo}"))
        |> send_resp(200, binario)

      {:error, _motivo} ->
        conn
        |> put_status(:unprocessable_entity)
        |> put_view(json: MetadataAppWeb.ErrorJSON)
        |> render(:"422")
    end
  end

  defp nombre_archivo_seguro(nombre) do
    nombre
    |> String.normalize(:nfd)
    |> String.replace(~r/[^A-Za-z0-9 _-]/u, "")
    |> String.trim()
    |> String.replace(~r/\s+/, "_")
    |> then(&(&1 == "" && "plantilla" || &1))
  end
end
