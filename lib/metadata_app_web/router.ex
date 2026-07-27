defmodule MetadataAppWeb.Router do
  use MetadataAppWeb, :router

  import MetadataAppWeb.UsuarioAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {MetadataAppWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_scope_for_usuario
  end

  pipeline :api do
    plug :accepts, ["json"]
    # Necesario para que requiere_permiso tenga un usuario_id/empresa_id
    # confiables (sesión de navegador vía cookie) — no habilita nada por sí
    # solo, un request sin sesión simplemente llega con current_scope vacío.
    plug :fetch_session
    plug :fetch_current_scope_for_usuario
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

    # Administración de RBAC (Fase 2 Paso 6) — mismo motivo que las de
    # arriba, nombres literales antes de "/:tabla".
    resources "/roles", RolController
    put "/roles/:id/permisos", RolController, :reemplazar_permisos
    resources "/permisos", PermisoController, only: [:index, :create]
    post "/usuarios/:usuario_id/roles", UsuarioRolController, :create
    delete "/usuarios/:usuario_id/roles/:rol_id", UsuarioRolController, :delete

    get "/catalogos/:tabla/impacto", BusinessProcessBuilder.CatalogoAdminController, :impacto
    get "/catalogos/:tabla/validar_motor", BusinessProcessBuilder.CatalogoAdminController, :validar_motor
    get "/catalogos/:tabla/completitud", BusinessProcessBuilder.CatalogoAdminController, :completitud
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

  # Mismo motivo que el scope /api y /dev de arriba: las rutas de auth
  # tienen que resolverse antes del comodín "/*ruta" de más abajo, si no
  # "/meta_schema_usuario/register" etc. caerían en CatalogoLive y jamás se
  # alcanzarían.
  scope "/", MetadataAppWeb do
    pipe_through [:browser, :require_authenticated_usuario]

    live_session :require_authenticated_usuario,
      on_mount: [{MetadataAppWeb.UsuarioAuth, :require_authenticated}] do
      live "/meta_schema_usuario/settings", UsuarioLive.Settings, :edit
      live "/meta_schema_usuario/settings/confirm-email/:token", UsuarioLive.Settings, :confirm_email
      live "/meta_schema_usuario/seleccionar-empresa", UsuarioLive.SeleccionarEmpresa, :new
    end

    post "/meta_schema_usuario/update-password", UsuarioSessionController, :update_password
    post "/meta_schema_usuario/empresa/:id/activar", EmpresaSessionController, :activar
  end

  scope "/", MetadataAppWeb do
    pipe_through [:browser]

    live_session :current_usuario,
      on_mount: [{MetadataAppWeb.UsuarioAuth, :mount_current_scope}] do
      live "/meta_schema_usuario/register", UsuarioLive.Registration, :new
      live "/meta_schema_usuario/log-in", UsuarioLive.Login, :new
      live "/meta_schema_usuario/log-in/:token", UsuarioLive.Confirmation, :new
    end

    post "/meta_schema_usuario/log-in", UsuarioSessionController, :create
    delete "/meta_schema_usuario/log-out", UsuarioSessionController, :delete
  end

  scope "/", MetadataAppWeb do
    pipe_through :browser

    live "/", InicioLive

    # Ni existen en producción — ni la ruta ni el link del Frame (ver
    # menu_layout.ex) tienen sentido ahí, no hay compilador para construir
    # nada. Compile-time (no Mix.env() en runtime, rompería en un release
    # compilado), mismo criterio que :dev_routes de arriba.
    if Application.compile_env(:metadata_app, :bpb_habilitado) do
      live "/sysadmin/bc-list", Sysadmin.BcListLive
      live "/sysadmin/bc-list/nuevo-completo", Sysadmin.BcNuevoCompletoLive
      live "/sysadmin/bc-list/:nombre/motor", Sysadmin.BcMotorLive
      live "/sysadmin/buscar-trn", Sysadmin.BuscadorTrnLive
    end

    # Administración de RBAC: siempre disponible (a diferencia del BPB de
    # arriba, esto no es una herramienta de desarrollador — administradores
    # en producción también necesitan gestionar roles/permisos).
    live "/sysadmin/roles", Sysadmin.RolesLive
    live "/sysadmin/roles/:id", Sysadmin.RolDetalleLive
    live "/sysadmin/usuarios", Sysadmin.UsuariosEmpresaLive
    live "/sysadmin/empresas", Sysadmin.EmpresasLive
    live "/sysadmin/catalogos/permisos", Sysadmin.CatalogoPermisosLive
    live "/sysadmin/catalogos/:recurso/permisos", Sysadmin.CatalogoPermisosLive

    # Comodín al final: cualquier ruta de navegación de un catálogo (con la
    # profundidad de carpetas que sea, ej. "/listas/motos" o
    # "/catalogos/carros") cae aquí. Va después de las rutas literales de
    # arriba para no taparlas.
    live "/*ruta", CatalogoLive
  end
end
