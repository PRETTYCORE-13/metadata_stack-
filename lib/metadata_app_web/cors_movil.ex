defmodule MetadataAppWeb.CorsMovil do
  @moduledoc """
  CORS para `/api/movil/*` (SPEC-API-0409202601) -- sin esto, un
  cliente corriendo en un navegador (`flutter run -d chrome`, o una
  futura build web) no puede llamar la API: los navegadores bloquean
  requests entre orígenes distintos si el servidor no manda estos
  headers explícitamente. No aplica a apps nativas (iOS/Android, el
  target real de esta API) -- CORS es un concepto exclusivo de
  navegadores. Encontrado real probando la app Flutter en Chrome,
  2026-09-04.

  Wildcard `*` en vez de un origen específico: esta API nunca usa
  cookies (el access token viaja en el header `Authorization`, no
  `credentials: include`), así que no hay sesión de otro origen que
  exponer -- el riesgo que `*` evita mitigar no aplica acá.
  """
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    conn
    |> put_resp_header("access-control-allow-origin", "*")
    |> put_resp_header("access-control-allow-methods", "GET, POST, PUT, PATCH, DELETE, OPTIONS")
    |> put_resp_header("access-control-allow-headers", "content-type, authorization")
    |> responder_si_preflight()
  end

  # El preflight OPTIONS que manda el navegador antes del request real
  # nunca llega al controller -- se responde acá mismo, vacío, con los
  # headers ya puestos arriba.
  defp responder_si_preflight(%{method: "OPTIONS"} = conn) do
    conn |> send_resp(204, "") |> halt()
  end

  defp responder_si_preflight(conn), do: conn
end
