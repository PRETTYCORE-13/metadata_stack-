defmodule MetadataAppWeb.EmpresaLogoController do
  @moduledoc """
  Entrega el logo de una empresa para la top bar y /sysadmin/empresas
  (SPEC-SYS-3009202601 D3). La versión va en la URL: cuando el logo cambia,
  cambia la URL, así que cada versión se puede cachear para siempre en el
  navegador y la base solo se consulta la primera vez que se ve.
  """

  use MetadataAppWeb, :controller

  alias MetadataApp.Autenticacion

  def mostrar(conn, %{"id" => id, "version" => version}) do
    usuario = conn.assigns.current_scope.usuario

    with {empresa_id, ""} <- Integer.parse(id),
         %{} = logo <- Autenticacion.obtener_logo_empresa(usuario, empresa_id),
         true <- Autenticacion.version_logo(logo.hash) == version do
      conn
      |> put_resp_content_type(logo.content_type, nil)
      # private: exige sesión, no debe quedar en una caché compartida.
      |> put_resp_header("cache-control", "private, max-age=31536000, immutable")
      |> put_resp_header("etag", ~s("#{version}"))
      |> send_resp(200, logo.contenido)
    else
      _ -> send_resp(conn, 404, "")
    end
  end
end
