defmodule MetadataAppWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :metadata_app

  # The session will be stored in the cookie and signed,
  # this means its contents can be read but not tampered with.
  # Set :encryption_salt if you would also like to encrypt it.
  @session_options [
    store: :cookie,
    key: "_metadata_app_key",
    signing_salt: "m5FNNxXG",
    same_site: "Lax"
  ]

  # :peer_data/:user_agent -- para poder auditar "desde dónde" (roadmap
  # #6, ver MetadataAppWeb.AuditoriaContexto.desde_socket/1) sin esto
  # get_connect_info/2 no tiene nada que devolver dentro de una LiveView.
  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [:peer_data, :user_agent, session: @session_options]],
    longpoll: [connect_info: [:peer_data, :user_agent, session: @session_options]]

  # Serve at "/" the static files from "priv/static" directory.
  #
  # gzip explícito por env (no atado a code_reloading?): un `mix
  # phx.digest` corrido alguna vez en dev deja app.css.gz/app.js.gz
  # obsoletos en priv/static -- si code_reloader se apaga (ver
  # config/dev.exs) sin este override, Plug.Static vuelve a preferir
  # ese .gz viejo sobre el build fresco y rompe el CSS en silencio
  # (encontrado en vivo, 2026-09-08).
  plug Plug.Static,
    at: "/",
    from: :metadata_app,
    gzip: Application.compile_env(:metadata_app, :static_gzip, false),
    only: MetadataAppWeb.static_paths()

  # Code reloading can be explicitly enabled under the
  # :code_reloader configuration of your endpoint.
  if code_reloading? do
    socket "/phoenix/live_reload/socket", Phoenix.LiveReloader.Socket
    plug Phoenix.LiveReloader
    plug Phoenix.CodeReloader
    plug Phoenix.Ecto.CheckRepoStatus, otp_app: :metadata_app
  end

  plug Phoenix.LiveDashboard.RequestLogger,
    param_key: "request_logger",
    cookie_key: "request_logger"

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options
  plug MetadataAppWeb.Router
end
