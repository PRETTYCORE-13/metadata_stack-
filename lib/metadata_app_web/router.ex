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

  scope "/api", MetadataAppWeb do
    pipe_through :api

    resources "/meta_schema_header", MetaSchemaHeaderController,
      only: [:index, :show, :create, :update]

    get "/catalogos/:tabla/impacto", CatalogoAdminController, :impacto
    delete "/catalogos/:tabla", CatalogoAdminController, :delete

    get "/:tabla/:id/transiciones", TransicionController, :index
    post "/:tabla/:id/transiciones/:accion", TransicionController, :ejecutar

    get "/:tabla", CatalogoController, :index
    get "/:tabla/:id", CatalogoController, :show
    post "/:tabla", CatalogoController, :create
    put "/:tabla/:id", CatalogoController, :update
    patch "/:tabla/:id", CatalogoController, :update
    delete "/:tabla/:id", CatalogoController, :delete
  end

  # Enable LiveDashboard and Swoosh mailbox preview in development
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
end
