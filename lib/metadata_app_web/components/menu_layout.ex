defmodule MetadataAppWeb.MenuLayout do
  use Phoenix.Component
  alias Phoenix.LiveView.JS

  # Props y slot
  attr :current_page, :string, required: true
  attr :menu_event, :string, default: "change_page"
  attr :show_programacion_children, :boolean, default: false
  attr :show_clientes_children, :boolean, default: false
  attr :show_prettycore_children, :boolean, default: false
  attr :sidebar_open, :boolean, default: false
  attr :current_user_email, :string, default: nil
  attr :current_user_name, :string, default: nil
  attr :current_user_id, :any, default: nil
  attr :notif_refresh, :integer, default: 0
  # Si se pasa, se usa tal cual (menú hardcodeado, ej. sysadmin). Si no, se
  # trae el dinámico desde meta_schema_header.
  attr :menu_items, :list, default: nil
  # RBAC (Fase 2): si viene un Scope con usuario+empresa_activa, el árbol se
  # poda por permisos ("leer" por catálogo) ANTES de renderizar — una sola
  # consulta a permisos_de_usuario/2 por render, nunca un can?/3 por nodo.
  # Deny-by-default estricto: un catálogo sin ese permiso concedido (exista
  # o no la fila en meta_schema_permiso) queda afuera. Sin scope resuelto,
  # el árbol se muestra completo (no hay de dónde sacar los permisos).
  attr :current_scope, :any, default: nil
  slot :inner_block, required: true

  def sidebar(assigns) do
    assigns =
      assigns
      |> assign(:menu_items, assigns.menu_items || MetadataApp.BusinessProcessBuilder.MetaSchemaContext.listar_menu_arbol())
      |> podar_menu_por_permisos()

    assigns =
      assigns
      |> assign(:nodo_actual, buscar_nodo_actual(assigns.menu_items, assigns.current_page))
      |> assign(:nombre_empresa, nombre_empresa_activa(assigns[:current_scope]))
      |> assign(:jerarquia_opciones, opciones_jerarquia_activa(assigns[:current_scope]))
      |> assign(:anio_actual, Date.utc_today().year)
      |> assign(:bpb_habilitado, Application.get_env(:metadata_app, :bpb_habilitado, false))
      |> asignar_datos_usuario()

    ~H"""
    <div class="pc-platform">
      <!-- Mobile overlay -->
      <div
        class="pc-sidebar-overlay"
        phx-click={mobile_toggle_js()}
      />
      <!-- Fila principal: riel + flyout + columna derecha (topbar +
           contenido), uno al lado del otro — el riel ocupa la altura
           COMPLETA de la pantalla (pedido explícito 2026-08-04), la topbar
           ya no vive afuera de esta fila: es la primera fila de la columna
           derecha, así que solo abarca el ancho a la derecha del riel. -->
      <div class="pc-platform-body">
      <!-- Sidebar: hermano de pc-platform-content — así el riel del menú
           ocupa todo el lado izquierdo, altura completa de la pantalla. -->
      <aside
        id="pc-sidebar"
        phx-hook="PersistirSidebarAbierto"
        class={"pc-platform-sidebar" <> if @sidebar_open, do: " pc-platform-sidebar-open", else: ""}
      >
        <div
          class="pc-sidebar-resize-handle"
          id="sidebar-resize-handle"
          phx-hook="RedimensionarSidebar"
          phx-update="ignore"
          title="Arrastra para ajustar el ancho del menú"
        >
        </div>
        <!-- HEADER: toggle (el branding ya vive en la topbar, a la
             derecha). -->
        <div class="pc-sidebar-header">
          <!-- Cerrar sidebar: solo visible en móvil -->
          <button type="button" class="pc-sidebar-close-mobile" phx-click={mobile_close_js()}>
            <svg fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round">
              <line x1="18" y1="6" x2="6" y2="18"/><line x1="6" y1="6" x2="18" y2="18"/>
            </svg>
          </button>
          <!-- Toggle colapso: solo visible en desktop (oculto en móvil via CSS) -->
          <button
            type="button"
            class="pc-sidebar-toggle"
            phx-click={toggle_sidebar_js(@menu_event)}
          >
            <%= if @sidebar_open do %>
              <svg width="19" height="19" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
                <polyline points="11 17 6 12 11 7" /><polyline points="18 17 13 12 18 7" />
              </svg>
            <% else %>
              <svg width="19" height="19" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
                <polyline points="13 17 18 12 13 7" /><polyline points="6 17 11 12 6 7" />
              </svg>
            <% end %>
          </button>
          <!-- Logo: en medio del toggle y los botones de tema (justify-
               content: space-between en pc-sidebar-header, ver menu.css) —
               antes vivía en la topbar, a pedido explícito se movió acá. -->
          <div class="pc-sidebar-logo">
            <img src="https://prettycore.xyz/IMAGENES/Logo%20Prettycore%20(8).png" alt="Prettycore" />
          </div>
          <!-- Tema claro/oscuro — reusa "phx:set-theme" (ya escuchado en
               root.html.heex desde que existe la app, generado por
               mix phx.new; acá recién se agrega el botón que lo dispara).
               Sin `detail:` en JS.dispatch a propósito: el listener lee
               `e.target.dataset.phxTheme` del botón, no un detail del
               evento — mismo contrato que Layouts.theme_toggle/1 (que
               vive sin uso real en el layout de demo). -->
          <div class="pc-theme-toggle">
            <button type="button" class="pc-theme-btn" phx-click={JS.dispatch("phx:set-theme")} data-phx-theme="light" title="Tema claro" aria-label="Cambiar a tema claro">
              <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
                <circle cx="12" cy="12" r="4" />
                <path d="M12 2v2M12 20v2M4.93 4.93l1.41 1.41M17.66 17.66l1.41 1.41M2 12h2M20 12h2M6.34 17.66l-1.41 1.41M19.07 4.93l-1.41 1.41" />
              </svg>
            </button>
            <button type="button" class="pc-theme-btn" phx-click={JS.dispatch("phx:set-theme")} data-phx-theme="dark" title="Tema oscuro" aria-label="Cambiar a tema oscuro">
              <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
                <path d="M21 12.79A9 9 0 1 1 11.21 3 7 7 0 0 0 21 12.79Z" />
              </svg>
            </button>
          </div>
        </div>

        <!-- CUERPO DEL MENÚ -->
        <div class="pc-sidebar-body">
          <div>
            <div class="px-3 pb-2 pt-3 pc-sidebar-search">
              <input
                type="text"
                id="filtro-menu"
                phx-hook="FiltroMenu"
                phx-update="ignore"
                placeholder="Buscar o pegar una ruta..."
                class="w-full text-sm border border-gray-300 rounded-lg px-3 py-1.5 text-gray-900"
              />
            </div>

            <nav class="pc-sidebar-nav" id="pc-sidebar-nav" phx-hook="EvitarToggleNativoCarpetas">
              <.menu_nodos
                nodos={@menu_items}
                current_page={@current_page}
                sidebar_open={@sidebar_open}
                menu_event={@menu_event}
              />
            </nav>
          </div>
        </div>
      </aside>
      <!-- FLYOUT: panel que aparece pegado al borde derecho del riel al abrir
           una carpeta raíz (nivel 0), mostrando SOLO las opciones de esa
           carpeta — sin tocar el árbol/estilo de arriba, que sigue
           funcionando exactamente igual. Mostrar/ocultar es 100% CSS
           (:has() sobre el [open] nativo del <details> de arriba, ver
           .pc-sidebar-flyout en menu.css), sin JS ni ida al servidor — y
           `name="pc-menu-raiz-group"` (puesto en menu_nodos/1) hace que el
           navegador se encargue solo de que abrir una carpeta raíz cierre
           cualquier otra, como un accordion nativo. -->
      <div class="pc-sidebar-flyout" id="pc-sidebar-flyout">
        <!-- Ajustable igual que el riel principal (mismo mecanismo de
             arrastre, ver RedimensionarFlyout en app.js) — su propia
             variable CSS/llave de localStorage, así no se pisan entre sí. -->
        <div
          class="pc-flyout-resize-handle"
          id="flyout-resize-handle"
          phx-hook="RedimensionarFlyout"
          phx-update="ignore"
          title="Arrastra para ajustar el ancho del submenú"
        >
        </div>
        <%= for {nodo, idx} <- Enum.with_index(@menu_items), nodo.tipo == :carpeta do %>
          <div class={"pc-flyout-panel pc-flyout-panel-#{idx}"} id={"pc-flyout-panel-#{idx}"}>
            <div class="pc-flyout-header">
              <span class="pc-flyout-header-nombre">{nodo.nombre}</span>
              <button
                type="button"
                class="pc-flyout-cerrar"
                phx-click={JS.remove_attribute("open", to: "#menu-carpeta-#{nodo.segmento}")}
                title="Cerrar"
                aria-label="Cerrar submenú"
              >
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round">
                  <line x1="18" y1="6" x2="6" y2="18"/><line x1="6" y1="6" x2="18" y2="18"/>
                </svg>
              </button>
            </div>
            <nav class="pc-flyout-nav">
              <.menu_nodos
                nodos={nodo.hijos}
                current_page={@current_page}
                sidebar_open={true}
                menu_event={@menu_event}
                ruta_padre={nodo.segmento}
                id_prefix="flyout-carpeta-"
                con_flyout={false}
              />
            </nav>
          </div>
        <% end %>
      </div>
      <!-- Columna derecha: topbar + contenido + footer, al lado del riel
           (que ahora ocupa la altura completa — ver comentario en
           pc-platform-body más arriba). La topbar es la primera fila de
           esta columna, así que solo abarca este ancho, no el de la
           pantalla completa. -->
      <div class="pc-platform-content">
      <div class="pc-topbar">
        <!-- Hamburger: solo visible en móvil -->
        <button
          type="button"
          class="pc-mobile-menu-btn"
          phx-click={mobile_toggle_js()}
        >
          <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
            <line x1="3" y1="6" x2="21" y2="6" /><line x1="3" y1="12" x2="21" y2="12" /><line x1="3" y1="18" x2="21" y2="18" />
          </svg>
        </button>
        <.link navigate="/" class="pc-topbar-brand">
          <span class="pc-topbar-empresa">{@nombre_empresa}</span>
        </.link>
        <div class="pc-topbar-derecha">
          <.live_component
            module={MetadataAppWeb.NotifBellComponent}
            id="notif-bell"
            user_id={@current_user_id}
            refresh={@notif_refresh}
          />
          <!-- Usuario: antes vivía abajo del todo en el sidebar (sección
               "Cuenta"), ahora es un solo botón acá con menú desplegable —
               reemplaza también al link viejo de "Iniciar sesión". -->
          <div class="pc-user-menu">
            <button
              type="button"
              class="pc-user-menu-btn"
              phx-click={
                JS.toggle(
                  to: "#user-menu-dropdown",
                  display: "flex",
                  in: {"ease-out duration-150", "opacity-0 scale-95", "opacity-100 scale-100"},
                  out: {"ease-in duration-100", "opacity-100 scale-100", "opacity-0 scale-95"}
                )
              }
            >
              <%= if @current_scope && @current_scope.usuario do %>
                <img
                  src={MetadataApp.Autenticacion.Usuario.avatar_url(@current_scope.usuario, 56)}
                  class="pc-user-menu-avatar pc-user-menu-avatar-img"
                />
              <% else %>
                <div class="pc-user-menu-avatar">
                  {((@current_user_name && String.first(@current_user_name)) || "?") |> String.upcase()}
                </div>
              <% end %>
              <span class="pc-user-menu-label">{@current_user_name || "Usuario"}</span>
            </button>
            <div
              id="user-menu-dropdown"
              class="pc-user-menu-dropdown"
              phx-click-away={JS.hide(to: "#user-menu-dropdown")}
            >
              <details class="pc-user-menu-submenu">
                <summary class="pc-user-menu-item pc-user-menu-item-submenu">Sysadmin</summary>
                <.link :if={@bpb_habilitado} navigate="/sysadmin/bc-list" class="pc-user-menu-item pc-user-menu-subitem">
                  Business Process Builder
                </.link>
                <.link :if={@bpb_habilitado} navigate="/sysadmin/tepache" class="pc-user-menu-item pc-user-menu-subitem">
                  Tepache Exp/Imp
                </.link>
                <.link navigate="/sysadmin/empresas" class="pc-user-menu-item pc-user-menu-subitem">
                  Empresas
                </.link>
                <.link navigate="/sysadmin/usuarios" class="pc-user-menu-item pc-user-menu-subitem">
                  Usuarios de la empresa
                </.link>
                <.link navigate="/sysadmin/roles" class="pc-user-menu-item pc-user-menu-subitem">
                  Roles y Usuarios
                </.link>
                <.link navigate="/sysadmin/catalogos/permisos" class="pc-user-menu-item pc-user-menu-subitem">
                  Permission Sets
                </.link>
                <.link navigate="/sysadmin/credenciales" class="pc-user-menu-item pc-user-menu-subitem">
                  Credenciales
                </.link>
                <.link navigate="/sysadmin/acciones-externas" class="pc-user-menu-item pc-user-menu-subitem">
                  Acciones externas
                </.link>
                <.link navigate="/sysadmin/jerarquia" class="pc-user-menu-item pc-user-menu-subitem">
                  Jerarquía organizacional
                </.link>
              </details>
              <button
                type="button"
                class="pc-user-menu-item"
                phx-click={
                  JS.hide(to: "#user-menu-dropdown")
                  |> JS.push("abrir", target: "#config-cuenta-modal")
                }
              >
                Configuración de cuenta
              </button>
              <.link
                href="/meta_schema_usuario/log-out"
                method="delete"
                class="pc-user-menu-item pc-user-menu-item-danger"
                data-confirm="¿Cerrar sesión?"
              >
                Cerrar sesión
              </.link>
            </div>
          </div>
        </div>
      </div>
      <.live_component module={MetadataAppWeb.ConfiguracionCuentaModal} id="config-cuenta-modal" current_scope={@current_scope} />
      <!-- CONTENIDO -->
      <main class="pc-platform-main">
          <%!-- Banda de publicidad (valores por defecto, sin backend todavía)
            banda_texto = "¿Tienes alguna idea de app web y no sabes cómo hacerla realidad? CONTÁCTANOS"
            banda_color = "#4f46e5"

          <div class="w-full overflow-hidden whitespace-nowrap" style={"background-color: #{banda_color}"}>
            <div class="inline-flex animate-marquee">
              <%= for _ <- 1..6 do %>
                <span class="px-8 py-2 text-sm font-semibold text-white tracking-wide">
                  <%= banda_texto %>
                </span>
              <% end %>
            </div>
          </div>
          --%>
          {render_slot(@inner_block)}
        </main>

      <!-- Footer: copyright de la plataforma + botón de copiar la ruta
           actual (ver assets/js/app.js CopiarRuta) — antes vivía arriba,
           se movió acá para dejar la topbar solo con branding/acciones.
           La ruta en sí (texto) se sacó (2026-08-04, a pedido explícito):
           el navegador ya la muestra en la URL, mostrarla de nuevo acá era
           redundante — el botón de copiar sigue funcionando igual, solo
           que ahora sin el texto al lado. El buscador TRN también se movió
           acá (antes en la topbar) — misma razón que el resto de esta
           banda: dejar la topbar solo con branding/acciones. -->
      <div class="pc-footer">
        <span class="pc-footer-copyright">Prettycore {@anio_actual}</span>

        <!-- Jerarquía operativa activa (Fase 4, 2026-08-11) — 4 selectores
             independientes, cada uno un form POST plano (id va en el
             body, no en la URL) que se auto-envía al cambiar el <select>
             (onchange="this.form.requestSubmit()"), sin fetch/JS hook:
             mismo criterio "funciona igual desde cualquier pantalla" que
             el buscador TRN de más abajo. Solo aparece con sesión+empresa
             resueltas -- ver opciones_jerarquia_activa/1. -->
        <div :if={@jerarquia_opciones.empresas != []} class="pc-footer-jerarquia">
          <div class="pc-footer-jerarquia-item">
            <span class="pc-footer-jerarquia-label">Empresa</span>
            <form method="post" action="/meta_schema_usuario/empresa/activar">
              <input type="hidden" name="_csrf_token" value={Phoenix.Controller.get_csrf_token()} />
              <select name="id" class="pc-footer-jerarquia-select" onchange="this.form.requestSubmit()">
                <option
                  :for={empresa <- @jerarquia_opciones.empresas}
                  value={empresa.id}
                  selected={@current_scope.empresa_activa && @current_scope.empresa_activa.id == empresa.id}
                >
                  {empresa.nombre}
                </option>
              </select>
            </form>
          </div>

          <div :if={@jerarquia_opciones.branches != []} class="pc-footer-jerarquia-item">
            <span class="pc-footer-jerarquia-label">Sucursal</span>
            <form method="post" action="/meta_schema_usuario/branch/activar">
              <input type="hidden" name="_csrf_token" value={Phoenix.Controller.get_csrf_token()} />
              <select name="id" class="pc-footer-jerarquia-select" onchange="this.form.requestSubmit()">
                <option value="" disabled selected={is_nil(@current_scope.branch_activo)}>Elegir...</option>
                <option
                  :for={branch <- @jerarquia_opciones.branches}
                  value={branch.id}
                  selected={@current_scope.branch_activo && @current_scope.branch_activo.id == branch.id}
                >
                  {branch.branch_name}
                </option>
              </select>
            </form>
          </div>

          <div :if={@jerarquia_opciones.inventory_locations != []} class="pc-footer-jerarquia-item">
            <span class="pc-footer-jerarquia-label">Almacén</span>
            <form method="post" action="/meta_schema_usuario/inventory-location/activar">
              <input type="hidden" name="_csrf_token" value={Phoenix.Controller.get_csrf_token()} />
              <select name="id" class="pc-footer-jerarquia-select" onchange="this.form.requestSubmit()">
                <option value="" disabled selected={is_nil(@current_scope.inventory_location_activo)}>Elegir...</option>
                <option
                  :for={inventory_location <- @jerarquia_opciones.inventory_locations}
                  value={inventory_location.id}
                  selected={@current_scope.inventory_location_activo && @current_scope.inventory_location_activo.id == inventory_location.id}
                >
                  {inventory_location.inventory_name}
                </option>
              </select>
            </form>
          </div>

          <div :if={@jerarquia_opciones.sales_units != []} class="pc-footer-jerarquia-item">
            <span class="pc-footer-jerarquia-label">Unidad de venta</span>
            <form method="post" action="/meta_schema_usuario/sales-unit/activar">
              <input type="hidden" name="_csrf_token" value={Phoenix.Controller.get_csrf_token()} />
              <select name="id" class="pc-footer-jerarquia-select" onchange="this.form.requestSubmit()">
                <option value="ninguna" selected={is_nil(@current_scope.sales_unit_activo)}>Ninguna</option>
                <option
                  :for={sales_unit <- @jerarquia_opciones.sales_units}
                  value={sales_unit.id}
                  selected={@current_scope.sales_unit_activo && @current_scope.sales_unit_activo.id == sales_unit.id}
                >
                  {sales_unit.sales_unit_name}
                </option>
              </select>
            </form>
          </div>
        </div>

        <%= if @nodo_actual do %>
          <button
            type="button"
            id="pc-breadcrumb-copiar"
            phx-hook="CopiarRuta"
            data-nav={@nodo_actual.nav}
            class="pc-breadcrumb-copiar"
            title="Copiar la ruta de esta página"
          >
            <svg class="pc-breadcrumb-copiar-icono-copiar" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
              <rect x="9" y="9" width="12" height="12" rx="2" />
              <path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1" />
            </svg>
            <svg class="pc-breadcrumb-copiar-icono-listo" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round">
              <polyline points="20 6 9 17 4 12" />
            </svg>
          </button>
        <% end %>

        <!-- Buscador TRN (PrettyCore TRN, Fase 3): form GET plano, no
             LiveView — navega directo a BuscadorTrnLive con ?query=...
             así funciona igual desde CUALQUIER pantalla que use este
             layout compartido, sin que cada LiveView tenga que
             implementar un handle_event en común. Siempre visible (a
             diferencia del resto del BPB): 2026-08-04, a pedido explícito
             — la ruta ya no depende de bpb_habilitado, ver router.ex. -->
        <form action="/sysadmin/buscar-trn" method="get" class="pc-footer-buscar-trn">
          <label for="footer-buscar-trn" class="pc-footer-buscar-trn-label">TRN:</label>
          <input type="text" name="query" id="footer-buscar-trn" autocomplete="off" class="pc-footer-buscar-trn-input" />
          <button type="submit" class="pc-footer-buscar-trn-btn" title="Buscar">
            <svg class="w-5 h-5" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2">
              <path stroke-linecap="round" stroke-linejoin="round" d="M21 21l-5.197-5.197m0 0A7.5 7.5 0 105.803 5.803a7.5 7.5 0 0010 10z" />
            </svg>
          </button>
        </form>
      </div>
      </div>
      </div>
    </div>
    """
  end

  ## MENÚ EN ÁRBOL — estilo explorador de Windows: nav="/carpeta/pagina" se
  # parte en carpetas colapsables (<details>, sin JS) con la página como hoja
  # al final. Ver MetadataApp.BusinessProcessBuilder.MetaSchemaContext.listar_menu_arbol/0.
  attr :nodos, :list, required: true
  attr :current_page, :string, required: true
  attr :nivel, :integer, default: 0
  # Una carpeta raíz (es_raiz_flotante) siempre fuerza el riel a colapsado
  # al abrirse (colapsar_sidebar_js/1) Y abre ESA carpeta puntual
  # (JS.set_attribute más abajo) — riel expandido (principal) y flyout
  # (secundario) son mutuamente excluyentes, nunca los dos abiertos a la
  # vez. Un JS.push le hace preventDefault al click, así que el toggle
  # NATIVO de <details> (el que pasaría solo, sin JS, con un click normal
  # en <summary>) nunca llega a dispararse solo — sin el set_attribute
  # explícito, el click solo colapsaría el riel sin abrir la carpeta
  # puntual que se clickeó.
  attr :sidebar_open, :boolean, default: true
  attr :menu_event, :string, default: "change_page"
  attr :ruta_padre, :string, default: ""
  # Prefijo del id del <details> de cada carpeta — por defecto el árbol
  # normal del riel ("menu-carpeta-..."). El flyout de abajo (pc-sidebar-
  # flyout) reusa este mismo componente para pintar los hijos de la
  # carpeta raíz activa, así que necesita su PROPIO prefijo ("flyout-
  # carpeta-...") para no terminar con dos elementos con el mismo id en
  # la página (uno en el riel, otro adentro del panel flotante).
  attr :id_prefix, :string, default: "menu-carpeta-"
  # Solo la carpeta raíz (nivel 0) del riel principal debe "ser" la que
  # dispara el flyout de al lado — ver pc-sidebar-flyout en sidebar/1, que
  # decide qué panel mostrar en CSS puro mirando el atributo nativo
  # [open] de estos <details> (sin JS: :has() + name= para que abrir una
  # se cierre la otra, como un accordion nativo). Cuando este componente
  # se llama para pintar el CONTENIDO de ese flyout (ver sidebar/1) pasa
  # con_flyout={false} para que sus propios nivel-0 internos no compitan
  # por el mismo grupo exclusivo que la carpeta raíz real.
  attr :con_flyout, :boolean, default: true

  def menu_nodos(assigns) do
    ~H"""
    <%= for {nodo, idx} <- Enum.with_index(@nodos) do %>
      <%= if nodo.tipo == :carpeta do %>
        <% ruta = if @ruta_padre == "", do: nodo.segmento, else: @ruta_padre <> "/" <> nodo.segmento %>
        <% id_carpeta = @id_prefix <> ruta %>
        <% es_raiz_flotante = @nivel == 0 and @con_flyout %>
        <% activo = contiene_activo?(nodo, @current_page) %>
        <details
          id={id_carpeta}
          class={["pc-menu-carpeta", es_raiz_flotante && "pc-carpeta-raiz", es_raiz_flotante && "pc-carpeta-raiz-#{idx}"]}
          name={es_raiz_flotante && "pc-menu-raiz-group"}
          open={activo}
        >
          <summary
            class={["pc-menu-carpeta-summary", @nivel == 0 && "pc-menu-carpeta-summary-raiz"]}
            style={"padding-left: #{12 + @nivel * 16}px"}
            phx-click={
              cond do
                # El toggle NATIVO de <summary> (el navegador abre/cierra el
                # <details> padre solo, aunque haya phx-click) está
                # bloqueado en fase de captura por el hook
                # EvitarToggleNativoCarpetas en app.js — sin eso, competía
                # con este set_attribute (confirmado con un
                # MutationObserver: quedaba en true y ~8ms después el
                # navegador lo revertía solo, sin importar si este phx-click
                # incluía un push o no).
                es_raiz_flotante ->
                  colapsar_sidebar_js(@menu_event) |> JS.set_attribute({"open", "true"}, to: "##{id_carpeta}")

                !@sidebar_open ->
                  toggle_sidebar_js(@menu_event) |> JS.set_attribute({"open", "true"}, to: "##{id_carpeta}")

                true ->
                  nil
              end
            }
          >
            <svg class="pc-menu-carpeta-icono-flecha w-3.5 h-3.5" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round">
              <polyline points="9 18 15 12 9 6" />
            </svg>
            <span class={["pc-menu-carpeta-icono-carpeta", activo && "pc-menu-carpeta-icono-carpeta-activo"]}>
              <%= if Map.get(nodo, :icono) not in [nil, ""] do %>
                <span class="material-symbols-outlined">{nodo.icono}</span>
              <% else %>
                <svg class="w-4 h-4 flex-shrink-0" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round">
                  <path d="M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V7z" />
                </svg>
              <% end %>
            </span>
            <!-- Solo se ve con el riel colapsado (ver .pc-menu-carpeta-nombre-corto
                 en menu.css) — con el riel expandido el nombre completo de
                 arriba ya alcanza, esto es para no dejar el ícono solo, sin
                 ninguna pista de qué sección es, cuando está colapsado. -->
            <span class="pc-menu-carpeta-nombre-corto">{String.slice(nodo.nombre, 0, 6)}</span>
            <span class="pc-menu-carpeta-nombre">{nodo.nombre}</span>
          </summary>
          <.menu_nodos
            nodos={nodo.hijos}
            current_page={@current_page}
            nivel={@nivel + 1}
            sidebar_open={@sidebar_open}
            menu_event={@menu_event}
            ruta_padre={ruta}
            id_prefix={@id_prefix}
          />
        </details>
      <% else %>
        <.link
          navigate={nodo.nav}
          phx-click={mobile_close_js()}
          class={menu_item_class(menu_active?(nodo.id, @current_page))}
          style={"padding-left: #{12 + @nivel * 16}px"}
        >
          <span class="pc-nav-icon"><.pc_icon name={nodo.id} icono={Map.get(nodo, :icono)} /></span>
          <span class="pc-nav-label">{nodo.label}</span>
        </.link>
      <% end %>
    <% end %>
    """
  end

  # Para que la carpeta que contiene la página activa empiece abierta, en
  # vez de tener que expandirla a mano cada vez que cargas la pantalla.
  defp contiene_activo?(%{tipo: :pagina, id: id}, current_page), do: id == current_page

  defp contiene_activo?(%{tipo: :carpeta, hijos: hijos}, current_page),
    do: Enum.any?(hijos, &contiene_activo?(&1, current_page))

  # Nodo de la página activa (label + nav) — se lo pasamos al hook de
  # "Favoritos y recientes" para que sepa qué registrar.
  defp buscar_nodo_actual(nodos, current_page) do
    Enum.find_value(nodos, fn
      %{tipo: :pagina, id: id} = nodo when id == current_page -> nodo
      %{tipo: :carpeta, hijos: hijos} -> buscar_nodo_actual(hijos, current_page)
      _ -> nil
    end)
  end

  ## ICONOS — outline style. Si el catálogo tiene un ícono de Material
  # Symbols configurado (schema_context_icono, elegido en BC Nuevo desde
  # fonts.google.com/icons), ese manda sobre todo lo demás. Si no, cae a los
  # íconos fijos de siempre (por nombre) y, en último caso, a un círculo
  # genérico.
  attr :name, :string, required: true
  attr :icono, :string, default: nil

  def pc_icon(assigns) do
    ~H"""
    <%= if @icono not in [nil, ""] do %>
      <span class="material-symbols-outlined">{@icono}</span>
    <% else %>
      <%= case @name do %>
        <% "inicio" -> %>
          <img src="/images/inicio.png" class="w-8 h-8 object-contain" />
        <% "tienda" -> %>
          <img src="/images/tienda.png" class="w-8 h-8 object-contain" />
        <% "pedidos" -> %>
          <img src="/images/pedidos.png" class="w-8 h-8 object-contain" />
        <% "usuarios" -> %>
          <img src="/images/usuarios.png" class="w-8 h-8 object-contain" />
        <% "disenador" -> %>
          <svg class="w-7 h-7" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round">
            <rect x="3" y="3" width="18" height="18" rx="2" />
            <path d="M3 9h18M9 21V9" />
          </svg>
        <% "logout" -> %>
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round">
            <path d="M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4" />
            <polyline points="16 17 21 12 16 7" />
            <line x1="21" y1="12" x2="9" y2="12" />
          </svg>
        <% _ -> %>
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" style="width: 16px; height: 16px;">
            <circle cx="12" cy="12" r="8" />
          </svg>
      <% end %>
    <% end %>
    """
  end

  # Nombre/correo del usuario para la topbar + modal de perfil — ningún
  # LiveView los pasa a mano (los attrs current_user_name/current_user_email
  # quedaban siempre nil), se derivan acá directo del Scope. Alias si lo
  # eligió, si no la parte del email antes de la @ (nunca "Usuario" a secas
  # mientras haya sesión real).
  # El nombre de la topbar reflejaba un valor fijo de config
  # (:nombre_empresa), NUNCA la empresa activa real de la sesión — con
  # varias empresas de prueba en la misma base, mostraba siempre lo mismo
  # sin importar en cuál estuviera parado el usuario (confusión real:
  # "estoy en DemoCore" cuando en realidad la sesión tenía otra empresa
  # activa). Ahora usa `current_scope.empresa_activa.nombre`; el config
  # fijo queda solo como fallback para cuando todavía no hay scope
  # resuelto (ej. login/register, donde este layout no se usa igual, pero
  # por las dudas).
  defp nombre_empresa_activa(%MetadataApp.Autenticacion.Scope{empresa_activa: %{nombre: nombre}}), do: nombre
  defp nombre_empresa_activa(_), do: Application.get_env(:metadata_app, :nombre_empresa, "Prettycore")

  # Opciones del selector de jerarquía operativa de la banda de pie (Fase
  # 4, 2026-08-11) — un query directo por render (mismo criterio que
  # nombre_empresa_activa/1 arriba, esto es un layout compartido por
  # TODAS las pantallas, no una carga que valga la pena cachear acá).
  # Sin usuario/empresa activa todavía (login, register) no hay contra
  # qué resolver nada -- listas vacías, el selector simplemente no
  # aparece (ver :if={@jerarquia_opciones.empresas != []} en el render).
  # Un "administrador" bypasea alcance_tipo_efectivo/2 por completo (ve
  # TODO sin importar la asignación) -- restringirle el selector de la
  # banda de pie a solo lo que tiene explícitamente asignado en
  # usuario_branch/usuario_inventory_location/usuario_sales_unit no tiene
  # sentido (probablemente ni tenga nada asignado, es sysadmin) y lo
  # dejaba SIN selector (encontrado en vivo: "Empresa" aparecía, branch/
  # inventory no, porque las listas volvían vacías). Ve TODAS las
  # opciones de la empresa activa en cambio -- mismo criterio que ya usa
  # alcance_tipo_efectivo/2 para el filtrado de datos.
  defp opciones_jerarquia_activa(%MetadataApp.Autenticacion.Scope{usuario: usuario, empresa_activa: empresa})
       when not is_nil(usuario) and not is_nil(empresa) do
    if MetadataApp.Permissions.administrador?(usuario.id, empresa.id) do
      %{
        empresas: MetadataApp.Autenticacion.empresas_de_usuario(usuario.id),
        branches: MetadataApp.Autenticacion.listar_branches(empresa.id),
        inventory_locations: MetadataApp.Autenticacion.listar_inventory_locations_de_empresa(empresa.id),
        sales_units: MetadataApp.Autenticacion.listar_sales_units_de_empresa(empresa.id)
      }
    else
      %{
        empresas: MetadataApp.Autenticacion.empresas_de_usuario(usuario.id),
        branches: MetadataApp.Autenticacion.branches_de_usuario(usuario.id, empresa.id),
        inventory_locations: MetadataApp.Autenticacion.inventory_locations_de_usuario(usuario.id, empresa.id),
        sales_units: MetadataApp.Autenticacion.sales_units_de_usuario(usuario.id, empresa.id)
      }
    end
  end

  defp opciones_jerarquia_activa(_scope), do: %{empresas: [], branches: [], inventory_locations: [], sales_units: []}

  defp asignar_datos_usuario(assigns) do
    case assigns[:current_scope] do
      %MetadataApp.Autenticacion.Scope{usuario: %MetadataApp.Autenticacion.Usuario{} = usuario} ->
        assigns
        |> assign(:current_user_name, MetadataApp.Autenticacion.Usuario.nombre_mostrar(usuario))
        |> assign(:current_user_email, usuario.email)
        |> assign(:current_user_id, usuario.id)

      _ ->
        assigns
    end
  end

  ## RBAC — poda del árbol por permisos (Fase 2, ver attr :current_scope)
  defp podar_menu_por_permisos(assigns) do
    case assigns[:current_scope] do
      %MetadataApp.Autenticacion.Scope{usuario: usuario, empresa_activa: empresa}
      when not is_nil(usuario) and not is_nil(empresa) ->
        permisos = MetadataApp.Permissions.permisos_de_usuario(usuario.id, empresa.id)
        assign(assigns, :menu_items, podar_nodos(assigns.menu_items, permisos))

      _ ->
        assigns
    end
  end

  defp podar_nodos(nodos, permisos) do
    nodos
    |> Enum.map(fn
      %{tipo: :carpeta, hijos: hijos} = nodo -> %{nodo | hijos: podar_nodos(hijos, permisos)}
      nodo -> nodo
    end)
    |> Enum.filter(fn
      %{tipo: :carpeta, hijos: hijos} -> hijos != []
      %{tipo: :pagina, id: id} -> Enum.any?(permisos, &(&1.recurso == id and &1.accion == "leer"))
    end)
  end

  ## HELPERS
  defp menu_active?(id, current), do: id == current

  defp menu_item_class(true), do: "pc-nav-item pc-nav-item-active"
  defp menu_item_class(false), do: "pc-nav-item"

  defp toggle_sidebar_js(menu_event) do
    JS.push(menu_event, value: %{id: "toggle_sidebar"})
    |> JS.toggle_class("pc-sidebar-visible", to: ".pc-platform-sidebar")
    |> JS.toggle_class("pc-sidebar-overlay-visible", to: ".pc-sidebar-overlay")
    |> cerrar_flyout_js()
  end

  # Abrir el riel (principal) cierra cualquier flyout de carpeta
  # (secundario) que haya quedado abierto — y viceversa, ver
  # colapsar_sidebar_js/1 más abajo, usado desde el click de una carpeta
  # raíz. `[name='pc-menu-raiz-group']` agarra el <details> que esté
  # abierto sin importar cuál — remove_attribute sobre uno ya cerrado no
  # hace nada, así que esto es seguro llamarlo siempre, se abra o se
  # cierre el riel.
  defp cerrar_flyout_js(js) do
    JS.remove_attribute(js, "open", to: "[name='pc-menu-raiz-group']")
  end

  # Click en una carpeta raíz del riel (la que dispara el flyout, ver
  # es_raiz_flotante en menu_nodos/1) — fuerza el riel a colapsado en vez
  # de tocarlo con un toggle, así abrir el flyout (secundario) siempre
  # cierra el riel expandido (principal), sin importar en qué estado
  # estuviera antes de este click.
  defp colapsar_sidebar_js(menu_event) do
    JS.push(menu_event, value: %{id: "colapsar_sidebar"})
  end

  defp mobile_toggle_js do
    JS.toggle_class("pc-sidebar-visible", to: ".pc-platform-sidebar")
    |> JS.toggle_class("pc-sidebar-overlay-visible", to: ".pc-sidebar-overlay")
  end

  defp mobile_close_js do
    JS.remove_class("pc-sidebar-visible", to: ".pc-platform-sidebar")
    |> JS.remove_class("pc-sidebar-overlay-visible", to: ".pc-sidebar-overlay")
  end

end
