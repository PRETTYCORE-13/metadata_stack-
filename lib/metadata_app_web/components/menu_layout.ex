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
  attr :user_role, :string, default: nil
  attr :user_permissions, :list, default: nil
  attr :current_user_id, :any, default: nil
  attr :notif_refresh, :integer, default: 0
  # Si se pasa, se usa tal cual (menú hardcodeado, ej. sysadmin). Si no, se
  # trae el dinámico desde meta_schema_header.
  attr :menu_items, :list, default: nil
  slot :inner_block, required: true

  def sidebar(assigns) do
    assigns =
      assigns
      |> assign(:menu_items, assigns.menu_items || MetadataApp.BusinessProcessBuilder.MetaSchemaContext.listar_menu_arbol())

    assigns =
      assigns
      |> assign(:nodo_actual, buscar_nodo_actual(assigns.menu_items, assigns.current_page))
      |> assign(:nombre_empresa, Application.get_env(:metadata_app, :nombre_empresa, "Prettycore"))
      |> assign(:anio_actual, Date.utc_today().year)

    ~H"""
    <div class="pc-platform">
      <!-- Topbar: logo + nombre de empresa (configurable, ver
           config/runtime.exs NOMBRE_EMPRESA — pensado para blanqueo de
           marca a futuro) + campana/login. -->
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
        <img
          src="https://prettycore.xyz/IMAGENES/Logo%20Prettycore%20(8).png"
          alt={@nombre_empresa}
          class="pc-topbar-logo"
        />
        <span class="pc-topbar-empresa">{@nombre_empresa}</span>
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
              <div class="pc-user-menu-avatar">
                {((@current_user_name && String.first(@current_user_name)) || "?") |> String.upcase()}
              </div>
              <span class="pc-user-menu-label">{@current_user_name || "Usuario"}</span>
            </button>
            <div
              id="user-menu-dropdown"
              class="pc-user-menu-dropdown"
              phx-click-away={JS.hide(to: "#user-menu-dropdown")}
            >
              <.link navigate="/sysadmin/bc-list" class="pc-user-menu-item">
                Business Process Builder
              </.link>
              <button
                type="button"
                class="pc-user-menu-item"
                phx-click={
                  JS.hide(to: "#user-menu-dropdown")
                  |> JS.show(
                    to: "#perfil-modal",
                    transition: {"ease-out duration-200", "opacity-0 scale-95", "opacity-100 scale-100"}
                  )
                }
              >
                Datos del usuario
              </button>
              <.link
                href="/logout"
                class="pc-user-menu-item pc-user-menu-item-danger"
                data-confirm="¿Cerrar sesión?"
              >
                Cerrar sesión
              </.link>
            </div>
          </div>
        </div>
      </div>
      <!-- Fila: Sidebar + Contenido -->
      <div class="pc-platform-row">
        <!-- Mobile overlay -->
        <div
          class="pc-sidebar-overlay"
          phx-click={mobile_toggle_js()}
        />
        <!-- Sidebar -->
        <aside class={"pc-platform-sidebar" <> if @sidebar_open, do: " pc-platform-sidebar-open", else: ""}>
          <div
            class="pc-sidebar-resize-handle"
            id="sidebar-resize-handle"
            phx-hook="RedimensionarSidebar"
            phx-update="ignore"
            title="Arrastra para ajustar el ancho del menú"
          >
          </div>
          <!-- HEADER: toggle (el branding ya vive en la topbar, arriba —
               repetirlo acá era redundante). -->
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

            <nav class="pc-sidebar-nav">
              <.menu_nodos nodos={@menu_items} current_page={@current_page} />
            </nav>
          </div>
        </div>
        </aside>
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
      </div>

      <!-- Footer: copyright de la plataforma + ruta completa de la página
           activa con botón de copiar (copia la URL completa, ver
           assets/js/app.js CopiarRuta) — antes vivía arriba, se movió acá
           para dejar la topbar solo con branding/acciones. La esquina
           derecha queda reservada para una función a futuro. -->
      <div class="pc-footer">
        <span class="pc-footer-copyright">Prettycore {@anio_actual}</span>
        <span class="pc-footer-separador">·</span>
        <.link navigate="/" class="pc-footer-ruta">{if @nodo_actual, do: @nodo_actual.nav, else: "/"}</.link>
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
      </div>

      <!-- ── Modal de perfil ── -->
      <div
        id="perfil-modal"
        class="hidden fixed inset-0 z-[999] flex items-center justify-center p-4"
        phx-click={JS.hide(to: "#perfil-modal", transition: {"ease-in duration-150", "opacity-100 scale-100", "opacity-0 scale-95"})}
      >
        <!-- Overlay -->
        <div class="absolute inset-0 bg-black/40 backdrop-blur-sm"></div>
        <!-- Tarjeta: detiene burbujeo para que no cierre el modal al hacer clic adentro -->
        <div
          class="relative bg-white rounded-3xl shadow-2xl w-full max-w-sm overflow-hidden"
          onclick="event.stopPropagation()"
        >
          <!-- Header con avatar grande -->
          <div class="bg-gray-900 px-6 pt-8 pb-6 flex flex-col items-center gap-3">
            <div class="w-20 h-20 rounded-full bg-purple-600 flex items-center justify-center text-white text-3xl font-black select-none shadow-lg">
              {((@current_user_name && String.first(@current_user_name)) || "?") |> String.upcase()}
            </div>
            <div class="text-center">
              <p class="text-white text-lg font-bold leading-tight">{@current_user_name || "Usuario"}</p>
              <%= if @user_role do %>
                <span class="inline-flex mt-1 items-center px-2.5 py-0.5 rounded-full text-xs font-semibold bg-purple-500/30 text-purple-200 border border-purple-500/40">
                  {String.capitalize(@user_role)}
                </span>
              <% end %>
            </div>
          </div>
          <!-- Datos -->
          <div class="px-6 py-5 space-y-3">
            <%= if @current_user_email && @current_user_email != "" do %>
              <div class="flex items-center gap-3">
                <div class="w-8 h-8 rounded-lg bg-gray-100 flex items-center justify-center flex-shrink-0">
                  <svg class="w-4 h-4 text-gray-500" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2">
                    <path stroke-linecap="round" stroke-linejoin="round" d="M3 8l7.89 5.26a2 2 0 002.22 0L21 8M5 19h14a2 2 0 002-2V7a2 2 0 00-2-2H5a2 2 0 00-2 2v10a2 2 0 002 2z"/>
                  </svg>
                </div>
                <div class="min-w-0">
                  <p class="text-[10px] text-gray-400 uppercase tracking-wide font-semibold">Correo</p>
                  <p class="text-sm text-gray-800 font-medium truncate">{@current_user_email}</p>
                </div>
              </div>
            <% end %>
            <%= if @user_role do %>
              <div class="flex items-center gap-3">
                <div class="w-8 h-8 rounded-lg bg-gray-100 flex items-center justify-center flex-shrink-0">
                  <svg class="w-4 h-4 text-gray-500" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2">
                    <path stroke-linecap="round" stroke-linejoin="round" d="M9 12l2 2 4-4m5.618-4.016A11.955 11.955 0 0112 2.944a11.955 11.955 0 01-8.618 3.04A12.02 12.02 0 003 9c0 5.591 3.824 10.29 9 11.622 5.176-1.332 9-6.03 9-11.622 0-1.042-.133-2.052-.382-3.016z"/>
                  </svg>
                </div>
                <div>
                  <p class="text-[10px] text-gray-400 uppercase tracking-wide font-semibold">Rol</p>
                  <p class="text-sm text-gray-800 font-medium">{String.capitalize(@user_role)}</p>
                </div>
              </div>
            <% end %>
            <%= if @user_permissions && @user_permissions != [] do %>
              <div class="flex items-start gap-3">
                <div class="w-8 h-8 rounded-lg bg-gray-100 flex items-center justify-center flex-shrink-0 mt-0.5">
                  <svg class="w-4 h-4 text-gray-500" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2">
                    <path stroke-linecap="round" stroke-linejoin="round" d="M15 7a2 2 0 012 2m4 0a6 6 0 01-7.743 5.743L11 17H9v2H7v2H4a1 1 0 01-1-1v-2.586a1 1 0 01.293-.707l5.964-5.964A6 6 0 1121 9z"/>
                  </svg>
                </div>
                <div class="min-w-0">
                  <p class="text-[10px] text-gray-400 uppercase tracking-wide font-semibold">Permisos</p>
                  <div class="flex flex-wrap gap-1 mt-1">
                    <%= for p <- @user_permissions do %>
                      <span class="inline-flex items-center px-2 py-0.5 rounded-md text-[10px] font-semibold bg-indigo-50 text-indigo-600 border border-indigo-100">
                        {String.capitalize(p)}
                      </span>
                    <% end %>
                  </div>
                </div>
              </div>
            <% end %>
          </div>
          <!-- Botón cerrar -->
          <div class="px-6 pb-5">
            <button
              type="button"
              class="w-full py-2.5 rounded-xl bg-gray-900 text-white text-sm font-semibold hover:bg-gray-700 transition-colors"
              phx-click={JS.hide(to: "#perfil-modal")}
            >
              Cerrar
            </button>
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

  def menu_nodos(assigns) do
    ~H"""
    <%= for nodo <- @nodos do %>
      <%= if nodo.tipo == :carpeta do %>
        <details class="pc-menu-carpeta" open={contiene_activo?(nodo, @current_page)}>
          <summary class="pc-menu-carpeta-summary" style={"padding-left: #{12 + @nivel * 16}px"}>
            <svg class="pc-menu-carpeta-icono-flecha w-3.5 h-3.5" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round">
              <polyline points="9 18 15 12 9 6" />
            </svg>
            <span class="pc-menu-carpeta-icono-carpeta">
              <%= if Map.get(nodo, :icono) not in [nil, ""] do %>
                <span class="material-symbols-outlined">{nodo.icono}</span>
              <% else %>
                <svg class="w-4 h-4 flex-shrink-0" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round">
                  <path d="M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V7z" />
                </svg>
              <% end %>
            </span>
            <span class="truncate">{nodo.nombre}</span>
          </summary>
          <.menu_nodos nodos={nodo.hijos} current_page={@current_page} nivel={@nivel + 1} />
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

  ## HELPERS
  defp menu_active?(id, current), do: id == current

  defp menu_item_class(true), do: "pc-nav-item pc-nav-item-active"
  defp menu_item_class(false), do: "pc-nav-item"

  defp toggle_sidebar_js(menu_event) do
    JS.push(menu_event, value: %{id: "toggle_sidebar"})
    |> JS.toggle_class("pc-sidebar-visible", to: ".pc-platform-sidebar")
    |> JS.toggle_class("pc-sidebar-overlay-visible", to: ".pc-sidebar-overlay")
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
