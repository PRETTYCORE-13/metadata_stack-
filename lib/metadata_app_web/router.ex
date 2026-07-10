defmodule MetadataAppWeb.Router do
  use MetadataAppWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {MetadataAppWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  # Va antes del scope "/" browser: el catch-all "/*ruta" de más abajo matchea
  # cualquier GET (incluido "/api/..."), así que /api tiene que resolverse
  # primero o esas rutas GET nunca llegarían a la API.
  scope "/api", MetadataAppWeb do
    pipe_through :api

    resources "/meta_schema_header", BusinessProcessBuilder.MetaSchemaHeaderController,
      only: [:index, :show, :create, :update]

    # Admin del autómata (definición): estados/transiciones/reglas. Van con
    # nombre literal, ANTES de los "/:tabla" genéricos de más abajo — si no,
    # "meta_schema_estados" etc. matchearían ahí como si fueran nombre de
    # catálogo (mismo motivo que el bug de scope /api vs /*ruta).
    resources "/meta_schema_estados", MetaEstadoController, only: [:index, :create]
    resources "/meta_schema_transiciones", MetaTransicionAdminController, only: [:index, :create]
    resources "/meta_schema_transicion_reglas", MetaTransicionReglaController, only: [:index, :create]

    get "/catalogos/:tabla/impacto", BusinessProcessBuilder.CatalogoAdminController, :impacto
    get "/catalogos/:tabla/validar_motor", BusinessProcessBuilder.CatalogoAdminController, :validar_motor
    delete "/catalogos/:tabla", BusinessProcessBuilder.CatalogoAdminController, :delete

    get "/:tabla/:id/transiciones", MetaTransicionController, :index
    post "/:tabla/:id/transiciones/:accion", MetaTransicionController, :ejecutar

    get "/:tabla", BusinessProcessBuilder.CatalogoController, :index
    get "/:tabla/:id", BusinessProcessBuilder.CatalogoController, :show
    post "/:tabla", BusinessProcessBuilder.CatalogoController, :create
    put "/:tabla/:id", BusinessProcessBuilder.CatalogoController, :update
    patch "/:tabla/:id", BusinessProcessBuilder.CatalogoController, :update
    delete "/:tabla/:id", BusinessProcessBuilder.CatalogoController, :delete
  end

  # Mismo motivo que el scope /api de arriba: también tiene que ir antes del
  # catch-all "/*ruta", si no "/dev/dashboard" y "/dev/mailbox" quedan
  # inalcanzables (el comodín las atrapa primero).
  if Application.compile_env(:metadata_app, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: MetadataAppWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end

  scope "/", MetadataAppWeb do
    pipe_through :browser

    live "/", InicioLive
    live "/sysadmin/bc-list", Sysadmin.BcListLive
    live "/sysadmin/bc-list/nuevo", Sysadmin.BcNuevoLive

    # Comodín al final: cualquier ruta de navegación de un catálogo (con la
    # profundidad de carpetas que sea, ej. "/listas/motos" o
    # "/catalogos/carros") cae aquí. Va después de las rutas literales de
    # arriba para no taparlas.
    live "/*ruta", CatalogoLive
  end
end
