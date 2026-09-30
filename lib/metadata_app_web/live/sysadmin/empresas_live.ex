defmodule MetadataAppWeb.Sysadmin.EmpresasLive do
  @moduledoc """
  Empresas (tenants) — listar, crear, renombrar. Crear una empresa te deja
  adentro como `administrador` automáticamente (ver
  `Autenticacion.crear_empresa_para_usuario/2`).

  Para un usuario normal, la lista es siempre "las mías". Para un
  `usuario.super_admin` (cross-empresa, ver el campo en
  `Autenticacion.Usuario`), la lista pasa a ser TODAS las empresas del
  sistema, con un botón "Unirme como admin" en las que todavía no
  pertenece (`Autenticacion.unirse_como_admin/2`) — la puerta de rescate
  que antes no existía para un tenant huérfano.
  """

  use MetadataAppWeb, :live_view_admin

  # Gateada desde 2026-08-16 (UI/permisos-sysadmin, a pedido explícito:
  # switch por pantalla de Sysadmin) -- antes quedaba deliberadamente
  # abierta para el bootstrap de un usuario recién registrado sin ningún
  # rol todavía, pero esta pantalla vive en live_session :app_autenticada
  # (router.ex), que ya exige :require_authenticated_con_empresa ANTES de
  # llegar acá -- alguien sin ninguna empresa nunca pasa de
  # /seleccionar-empresa (o del wizard de primer arranque) para
  # alcanzarla, así que el caso que esta excepción cubría ya no ocurre.
  on_mount {MetadataAppWeb.UsuarioAuth, :require_authenticated}
  on_mount {MetadataAppWeb.Hooks.Autorizacion, {"sysadmin_empresas", "leer"}}

  alias MetadataApp.Autenticacion
  alias MetadataApp.Autenticacion.ImagenLogo
  alias MetadataAppWeb.{AdminNav, MenuLayout}

  @menu [
    %{tipo: :pagina, id: "bc_list", label: "BC List", nav: "/sysadmin/bc-list"},
    %{tipo: :pagina, id: "buscar_trn", label: "Buscar TRN", nav: "/sysadmin/buscar-trn"},
    %{tipo: :pagina, id: "tepache", label: "Tepache Exp/Imp", nav: "/sysadmin/tepache"},
    %{tipo: :pagina, id: "roles", label: "Roles y Usuarios", nav: "/sysadmin/roles"},
    %{tipo: :pagina, id: "usuarios_empresa", label: "Usuarios", nav: "/sysadmin/usuarios"},
    %{tipo: :pagina, id: "empresas", label: "Empresas", nav: "/sysadmin/empresas"},
    %{tipo: :pagina, id: "credenciales", label: "Credenciales", nav: "/sysadmin/credenciales"},
    %{tipo: :pagina, id: "ambientes", label: "Ambientes de Deploy", nav: "/sysadmin/ambientes"},
    %{tipo: :pagina, id: "acciones_externas", label: "Acciones externas", nav: "/sysadmin/acciones-externas"},
    %{tipo: :pagina, id: "jerarquia", label: "Jerarquía organizacional", nav: "/sysadmin/jerarquia"},
  %{tipo: :pagina, id: "panel_control", label: "Panel Control", nav: "/sysadmin/panel-control"},
  %{tipo: :pagina, id: "sesiones_movil", label: "Sesiones móviles", nav: "/sysadmin/sesiones-movil"},
  %{tipo: :pagina, id: "endpoints", label: "Endpoints", nav: "/sysadmin/endpoints"},
  %{tipo: :pagina, id: "propagacion", label: "Propagación", nav: "/sysadmin/propagacion"},
  ]

  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:current_page, "empresas")
     |> assign(:menu_items, AdminNav.filtrar_menu(@menu))
     |> assign(:sidebar_open, false)
     |> assign(:show_programacion_children, false)
     |> assign(:show_clientes_children, false)
     |> assign(:show_prettycore_children, false)
     |> assign(:form_nueva_empresa, nil)
     |> assign(:error_form, nil)
     |> assign(:empresa_editando, nil)
     |> assign(:logo_pendiente, nil)
     |> assign(:error_logo, nil)
     |> allow_upload(:logo,
       accept: ~w(.png .jpg .jpeg .webp .gif),
       max_entries: 1,
       max_file_size: ImagenLogo.max_bytes(),
       auto_upload: true,
       progress: &handle_progress_logo/3
     )
     |> cargar_empresas()}
  end

  def handle_event("change_page", %{"id" => id}, socket) do
    AdminNav.handle_nav(id, socket, "empresas")
  end

  def handle_event("abrir_form_nueva", _params, socket) do
    {:noreply, assign(socket, form_nueva_empresa: %{"nombre" => ""}, error_form: nil)}
  end

  def handle_event("cerrar_form_nueva", _params, socket) do
    {:noreply, assign(socket, form_nueva_empresa: nil, error_form: nil)}
  end

  def handle_event("crear_empresa", %{"empresa" => %{"nombre" => nombre}}, socket) do
    usuario_id = socket.assigns.current_scope.usuario.id

    case Autenticacion.crear_empresa_para_usuario(nombre, usuario_id) do
      {:ok, _empresa} ->
        socket = socket |> assign(form_nueva_empresa: nil, error_form: nil) |> cargar_empresas()

        # `empresa_activa` solo se fija en la sesión al momento de loguearse
        # (ver UsuarioAuth.log_in_usuario/2) — si el usuario entró sin
        # ninguna empresa todavía (como cualquiera recién registrado, ver
        # el bootstrap de arriba), crearla acá no actualiza esa sesión. Sin
        # este redirect quedaría con acceso a "sus empresas" pero sin poder
        # usar Usuarios/Roles/Permisos, que dependen de saber en cuál está
        # activo. `seleccionar-empresa` ya resuelve esto con un solo click
        # (POST real a EmpresaSessionController, mismo mecanismo que usa
        # cualquiera con 2+ empresas).
        if is_nil(socket.assigns.current_scope.empresa_activa) do
          {:noreply, push_navigate(socket, to: ~p"/meta_schema_usuario/seleccionar-empresa")}
        else
          {:noreply, socket}
        end

      {:error, changeset} ->
        mensaje = changeset.errors |> Enum.map_join(", ", fn {campo, {msg, _}} -> "#{campo} #{msg}" end)
        {:noreply, assign(socket, :error_form, mensaje)}
    end
  end

  def handle_event("unirse_empresa", %{"id" => id}, socket) do
    usuario_id = socket.assigns.current_scope.usuario.id
    Autenticacion.unirse_como_admin(usuario_id, String.to_integer(id))
    {:noreply, cargar_empresas(socket)}
  end

  def handle_event("abrir_editar", %{"id" => id}, socket) do
    empresa = Enum.find(socket.assigns.empresas, &(&1.id == String.to_integer(id)))
    {:noreply, assign(socket, empresa_editando: empresa, error_form: nil)}
  end

  def handle_event("cerrar_editar", _params, socket) do
    {:noreply, socket |> descartar_logo_pendiente() |> assign(empresa_editando: nil, error_form: nil)}
  end

  # Con max_entries: 1, elegir otro archivo después de uno rechazado (ej.
  # :too_large) daría :too_many_files; se conserva solo la última entrada.
  def handle_event("validar_logo", _params, socket) do
    {anteriores, _ultima} = Enum.split(socket.assigns.uploads.logo.entries, -1)
    socket = Enum.reduce(anteriores, socket, &cancel_upload(&2, :logo, &1.ref))
    {:noreply, assign(socket, error_logo: nil)}
  end

  def handle_event("cancelar_carga_logo", %{"ref" => ref}, socket) do
    {:noreply, socket |> cancel_upload(:logo, ref) |> assign(error_logo: nil)}
  end

  def handle_event("descartar_logo", _params, socket) do
    {:noreply, descartar_logo_pendiente(socket)}
  end

  def handle_event("guardar_logo", _params, socket) do
    case socket.assigns.logo_pendiente do
      %{binario: binario} ->
        socket.assigns.empresa_editando
        |> Autenticacion.guardar_logo_empresa(binario)
        |> tras_cambiar_logo(socket, "Logo guardado.")

      nil ->
        {:noreply, socket}
    end
  end

  def handle_event("quitar_logo", _params, socket) do
    socket.assigns.empresa_editando
    |> Autenticacion.quitar_logo_empresa()
    |> tras_cambiar_logo(socket, "Logo quitado.")
  end

  def handle_event("guardar_empresa", %{"empresa" => attrs}, socket) do
    case Autenticacion.actualizar_empresa(socket.assigns.empresa_editando, attrs) do
      {:ok, _empresa} ->
        {:noreply, socket |> assign(empresa_editando: nil, error_form: nil) |> cargar_empresas()}

      {:error, changeset} ->
        mensaje = changeset.errors |> Enum.map_join(", ", fn {campo, {msg, _}} -> "#{campo} #{msg}" end)
        {:noreply, assign(socket, :error_form, mensaje)}
    end
  end

  # Bloqueado del lado del context si igual llega el evento con usuarios
  # asociados (ej. otra pestaña agregó uno mientras esta estaba abierta)
  # — el botón ya viene oculto en ese caso, esto es la defensa por si acaso.
  def handle_event("eliminar_empresa", %{"id" => id}, socket) do
    empresa = Enum.find(socket.assigns.empresas, &(&1.id == String.to_integer(id)))

    case Autenticacion.eliminar_empresa(empresa) do
      {:ok, _} ->
        {:noreply, cargar_empresas(socket)}

      {:error, :tiene_usuarios} ->
        {:noreply, put_flash(socket, :error, "No se puede eliminar \"#{empresa.nombre}\": todavía tiene usuarios asociados.")}
    end
  end

  # La vista previa sale de los bytes ya validados en el servidor (no del
  # archivo local del navegador): se ve exactamente lo que se va a guardar.
  defp handle_progress_logo(:logo, %{done?: true} = entry, socket) do
    binario = consume_uploaded_entry(socket, entry, fn %{path: path} -> {:ok, File.read!(path)} end)

    case ImagenLogo.inspeccionar(binario) do
      {:ok, info} ->
        pendiente =
          Map.merge(info, %{
            binario: binario,
            data_uri: "data:#{info.content_type};base64,#{Base.encode64(binario)}"
          })

        {:noreply, assign(socket, logo_pendiente: pendiente, error_logo: nil)}

      {:error, mensaje} ->
        {:noreply, assign(socket, logo_pendiente: nil, error_logo: mensaje)}
    end
  end

  defp handle_progress_logo(:logo, _entry, socket), do: {:noreply, socket}

  defp descartar_logo_pendiente(socket) do
    socket.assigns.uploads.logo.entries
    |> Enum.reduce(socket, &cancel_upload(&2, :logo, &1.ref))
    |> assign(logo_pendiente: nil, error_logo: nil)
  end

  # Editar la empresa activa cambia la top bar de quien la edita: se
  # re-monta la pantalla para que el scope traiga el logo_version nuevo.
  defp tras_cambiar_logo({:ok, empresa}, socket, mensaje) do
    socket = socket |> descartar_logo_pendiente() |> put_flash(:info, mensaje)
    activa = socket.assigns.current_scope.empresa_activa

    if activa && activa.id == empresa.id do
      {:noreply, push_navigate(socket, to: ~p"/sysadmin/empresas")}
    else
      {:noreply, socket |> assign(:empresa_editando, empresa) |> cargar_empresas()}
    end
  end

  defp tras_cambiar_logo({:error, mensaje}, socket, _mensaje) when is_binary(mensaje),
    do: {:noreply, assign(socket, error_logo: mensaje)}

  defp tras_cambiar_logo({:error, _}, socket, _mensaje),
    do: {:noreply, assign(socket, error_logo: "No se pudo guardar el logo; intenta de nuevo.")}

  defp error_upload_logo(:too_large), do: "El logo no puede pasar de 200 KB."
  defp error_upload_logo(:not_accepted), do: "Formato no permitido: usa PNG, JPG, WebP o GIF."
  defp error_upload_logo(:too_many_files), do: "Elige un solo archivo."
  defp error_upload_logo(_), do: "No se pudo subir el archivo; intenta de nuevo."

  defp cargar_empresas(socket) do
    usuario = socket.assigns.current_scope.usuario
    mis_empresas = Autenticacion.empresas_de_usuario(usuario.id)

    socket =
      if usuario.super_admin do
        mis_ids = MapSet.new(mis_empresas, & &1.id)

        socket
        |> assign(:empresas, Autenticacion.listar_empresas())
        |> assign(:mis_empresas_ids, mis_ids)
      else
        socket
        |> assign(:empresas, mis_empresas)
        |> assign(:mis_empresas_ids, MapSet.new(mis_empresas, & &1.id))
      end

    empresa_ids = Enum.map(socket.assigns.empresas, & &1.id)
    assign(socket, :usuarios_por_empresa, Autenticacion.contar_usuarios_por_empresa(empresa_ids))
  end

  def render(assigns) do
    ~H"""
    <div class="w-full p-4 sm:p-6 lg:p-8">
      <div class="flex items-center justify-between mb-4">
        <div class="flex items-center gap-2">
          <.link navigate={~p"/"} title="Volver al inicio"
            class="w-7 h-7 flex items-center justify-center rounded-lg text-gray-500 hover:bg-gray-100 hover:text-gray-700 transition-colors shrink-0">
            <span class="material-symbols-outlined" style="font-size: 18px">arrow_back</span>
          </.link>
          <h1 class="text-2xl font-bold">Empresas</h1>
        </div>
        <button
          type="button"
          phx-click="abrir_form_nueva"
          class="pc-btn-secundario bg-linear-to-b from-white to-gray-100 hover:to-gray-200 border border-gray-100 text-gray-800 shadow-sm font-semibold text-xs px-4 py-1.5 rounded-full transition-colors"
        >
          + Nueva empresa
        </button>
      </div>
      <p class="text-sm text-gray-500 mb-6">
        <%= if @current_scope.usuario.super_admin do %>
          Todas las empresas del sistema (eres super admin) — crear una, o unirte como administrador a una que ya existe.
        <% else %>
          Las empresas a las que perteneces — crear una te deja adentro como administrador.
        <% end %>
      </p>

      <div class="overflow-x-auto rounded-xl border border-gray-200">
        <table class="min-w-full divide-y divide-gray-200">
          <thead class="bg-gray-50">
            <tr>
              <th class="px-4 py-3 text-left text-xs font-semibold text-gray-500 uppercase tracking-wide">Nombre</th>
              <th class="px-4 py-3 text-left text-xs font-semibold text-gray-500 uppercase tracking-wide">Logo</th>
              <th class="px-4 py-3"></th>
            </tr>
          </thead>
          <tbody class="divide-y divide-gray-100">
            <tr :for={empresa <- @empresas} class="hover:bg-purple-50/60">
              <td class="px-4 py-2 text-sm text-gray-900">
                {empresa.nombre}
                <span
                  :if={@current_scope.empresa_activa && @current_scope.empresa_activa.id == empresa.id}
                  class="ml-2 inline-flex items-center px-2 py-0.5 rounded-full text-xs font-semibold bg-purple-50 text-purple-700 border border-purple-100"
                >
                  Activa
                </span>
              </td>
              <td class="px-4 py-2">
                <%= if url = MenuLayout.url_logo_empresa(empresa) do %>
                  <MenuLayout.logo_empresa id={"logo-empresa-#{empresa.id}"} src={url} nombre={empresa.nombre} />
                <% else %>
                  <span class="text-sm text-gray-400">—</span>
                <% end %>
              </td>
              <td class="px-4 py-2 text-right whitespace-nowrap">
                <button
                  :if={!MapSet.member?(@mis_empresas_ids, empresa.id)}
                  type="button"
                  phx-click="unirse_empresa"
                  phx-value-id={empresa.id}
                  class="text-xs text-purple-700 font-semibold hover:underline mr-3"
                >
                  Unirme como admin
                </button>
                <button
                  type="button"
                  id={"editar-empresa-#{empresa.id}"}
                  phx-click="abrir_editar"
                  phx-value-id={empresa.id}
                  class="text-xs text-purple-700 hover:underline mr-3"
                >
                  Editar
                </button>
                <button
                  :if={Map.get(@usuarios_por_empresa, empresa.id, 0) == 0}
                  type="button"
                  phx-click="eliminar_empresa"
                  phx-value-id={empresa.id}
                  data-confirm={"¿Eliminar \"#{empresa.nombre}\"? No se puede deshacer."}
                  class="text-xs text-red-600 hover:underline"
                >
                  Eliminar
                </button>
              </td>
            </tr>
            <tr :if={@empresas == []}>
              <td colspan="3" class="px-4 py-6 text-center text-sm text-gray-400">
                Todavía no perteneces a ninguna empresa.
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <div :if={@form_nueva_empresa} class="fixed inset-0 bg-black/40 flex items-center justify-center z-50">
        <div class="bg-white rounded-xl shadow-lg max-w-sm w-full p-6">
          <h2 class="text-lg font-bold mb-4">Nueva empresa</h2>
          <form phx-submit="crear_empresa">
            <div class="mb-4">
              <label class="text-xs font-semibold text-gray-500">Nombre</label>
              <input
                type="text"
                name="empresa[nombre]"
                required
                class="w-full border border-gray-300 rounded-lg px-3 py-2 text-sm text-gray-900"
              />
            </div>
            <p :if={@error_form} class="text-xs text-red-600 mb-3">{@error_form}</p>
            <div class="flex justify-end gap-2">
              <button type="button" phx-click="cerrar_form_nueva" class="px-4 py-2 rounded border border-gray-300 text-gray-700 text-sm font-semibold hover:bg-gray-50">
                Cancelar
              </button>
              <button type="submit" class="px-4 py-2 rounded bg-purple-600 text-white text-sm font-semibold hover:bg-purple-700">
                Crear
              </button>
            </div>
          </form>
        </div>
      </div>

      <div :if={@empresa_editando} class="fixed inset-0 bg-black/40 flex items-center justify-center z-50">
        <div class="bg-white rounded-xl shadow-lg max-w-md w-full p-6 max-h-[90vh] overflow-y-auto">
          <h2 class="text-lg font-bold mb-4">Editar empresa</h2>
          <form id="empresa-nombre-form" phx-submit="guardar_empresa">
            <div class="mb-4">
              <label class="text-xs font-semibold text-gray-500">Nombre</label>
              <input
                type="text"
                name="empresa[nombre]"
                value={@empresa_editando.nombre}
                required
                class="w-full border border-gray-300 rounded-lg px-3 py-2 text-sm text-gray-900"
              />
            </div>
            <p :if={@error_form} class="text-xs text-red-600 mb-3">{@error_form}</p>
            <div class="flex justify-end gap-2">
              <button type="button" phx-click="cerrar_editar" class="px-4 py-2 rounded border border-gray-300 text-gray-700 text-sm font-semibold hover:bg-gray-50">
                Cancelar
              </button>
              <button type="submit" class="px-4 py-2 rounded bg-purple-600 text-white text-sm font-semibold hover:bg-purple-700">
                Guardar
              </button>
            </div>
          </form>

          <.seccion_logo
            empresa={@empresa_editando}
            upload={@uploads.logo}
            pendiente={@logo_pendiente}
            error={@error_logo}
          />
        </div>
      </div>
    </div>
    """
  end

  attr :empresa, :map, required: true
  attr :upload, :any, required: true
  attr :pendiente, :map, default: nil
  attr :error, :string, default: nil

  defp seccion_logo(assigns) do
    assigns =
      assign(assigns,
        url_actual: MenuLayout.url_logo_empresa(assigns.empresa),
        errores_upload:
          Enum.map(upload_errors(assigns.upload), &error_upload_logo/1) ++
            Enum.flat_map(assigns.upload.entries, &Enum.map(upload_errors(assigns.upload, &1), fn e -> error_upload_logo(e) end)),
        cargando: Enum.find(assigns.upload.entries, &(!&1.done? and upload_errors(assigns.upload, &1) == []))
      )

    ~H"""
    <section id="logo-empresa-seccion" class="mt-6 pt-5 border-t border-gray-200">
      <h3 class="text-sm font-bold text-gray-800 mb-1">Logo</h3>
      <p id="logo-empresa-recomendacion" class="text-xs text-gray-500 mb-3">
        PNG o WebP con fondo transparente, horizontal, 320 × 64 px (proporción 5:1), máximo 200 KB.
      </p>

      <%!-- Vista previa: mismo componente y caja que la top bar. --%>
      <div class="mb-3">
        <p class="text-xs font-semibold text-gray-500 mb-1">
          {if @pendiente, do: "Vista previa en la barra superior", else: "Logo actual"}
        </p>
        <div class="flex items-center gap-2.5 rounded-lg border border-gray-200 bg-[var(--pc-bg-secundario)] px-4 py-1.5 min-h-11">
          <%= cond do %>
            <% @pendiente -> %>
              <MenuLayout.logo_empresa id="logo-empresa-vista-previa" src={@pendiente.data_uri} nombre={@empresa.nombre} />
            <% @url_actual -> %>
              <MenuLayout.logo_empresa id="logo-empresa-actual" src={@url_actual} nombre={@empresa.nombre} />
            <% true -> %>
              <span class="text-xs text-gray-400">Sin logo</span>
          <% end %>
          <span class="pc-topbar-empresa">{@empresa.nombre}</span>
        </div>
        <p :if={@pendiente} class="text-xs text-gray-500 mt-1">
          {@pendiente.ancho} × {@pendiente.alto} px · {Float.round(@pendiente.tamano_bytes / 1024, 1)} KB
        </p>
        <p :if={@pendiente && @pendiente.aviso_proporcion} id="logo-empresa-aviso-proporcion" class="text-xs text-amber-700 mt-1">
          La imagen no es horizontal o se sale de la proporción recomendada: se verá más chica de lo ideal.
        </p>
      </div>

      <form id="logo-empresa-form" phx-change="validar_logo" phx-submit="guardar_logo">
        <%!-- Mientras sube, la barra reemplaza al área de carga. El label se
             oculta pero no se quita: el live_file_input debe seguir en el
             DOM para que la subida continúe. --%>
        <div
          :if={@cargando}
          id="logo-empresa-progreso"
          role="progressbar"
          aria-label="Subiendo logo"
          aria-valuemin="0"
          aria-valuemax="100"
          aria-valuenow={@cargando.progress}
          class="w-full rounded-lg border border-purple-200 bg-purple-50/50 px-3 py-2.5"
        >
          <div class="flex items-center justify-between gap-3 text-xs text-gray-600 mb-1.5">
            <span class="truncate">Subiendo {@cargando.client_name}</span>
            <span class="font-semibold text-purple-700 tabular-nums">{@cargando.progress}%</span>
          </div>
          <div class="flex items-center gap-3">
            <div class="h-2 flex-1 rounded-full bg-gray-200 overflow-hidden">
              <div class="h-full rounded-full bg-purple-600 transition-[width] duration-200 ease-out" style={"width: #{@cargando.progress}%"}></div>
            </div>
            <button
              type="button"
              id="logo-empresa-cancelar-carga"
              phx-click="cancelar_carga_logo"
              phx-value-ref={@cargando.ref}
              class="text-xs font-semibold text-gray-600 hover:text-red-600 transition-colors"
            >
              Cancelar
            </button>
          </div>
        </div>
        <label
          for={@upload.ref}
          phx-drop-target={@upload.ref}
          class={[
            "flex items-center justify-center gap-2 w-full border-2 border-dashed border-gray-300 rounded-lg px-3 py-3 text-sm text-gray-600 cursor-pointer hover:border-purple-400 hover:bg-purple-50/50 transition-colors",
            @cargando && "hidden"
          ]}
        >
          <span class="material-symbols-outlined" style="font-size: 18px">upload</span>
          {if @url_actual || @pendiente, do: "Elegir otro archivo", else: "Elegir archivo"}
          <.live_file_input upload={@upload} class="sr-only" />
        </label>

        <p :for={mensaje <- Enum.uniq(@errores_upload ++ List.wrap(@error))} class="logo-empresa-error text-xs text-red-600 mt-2">
          {mensaje}
        </p>

        <div class="flex justify-end gap-2 mt-3">
          <button
            :if={@url_actual && !@pendiente}
            type="button"
            id="logo-empresa-quitar"
            phx-click="quitar_logo"
            data-confirm="¿Quitar el logo? La barra superior mostrará solo el nombre."
            class="px-4 py-2 rounded border border-red-200 text-red-600 text-sm font-semibold hover:bg-red-50 transition-colors"
          >
            Quitar logo
          </button>
          <button
            :if={@pendiente}
            type="button"
            id="logo-empresa-descartar"
            phx-click="descartar_logo"
            class="px-4 py-2 rounded border border-gray-300 text-gray-700 text-sm font-semibold hover:bg-gray-50 transition-colors"
          >
            Descartar
          </button>
          <button
            :if={@pendiente}
            type="submit"
            id="logo-empresa-guardar"
            class="px-4 py-2 rounded bg-purple-600 text-white text-sm font-semibold hover:bg-purple-700 transition-colors"
          >
            Guardar logo
          </button>
        </div>
      </form>
    </section>
    """
  end
end
