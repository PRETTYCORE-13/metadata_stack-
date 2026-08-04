defmodule MetadataAppWeb.ConfiguracionCuentaModal do
  use MetadataAppWeb, :live_component

  alias MetadataApp.Autenticacion
  alias MetadataApp.Notificaciones

  # Estilos explícitos (no clases de daisyUI tipo "input"/"btn-primary",
  # que dependen del theme activo — data-theme="dark" en la página de
  # atrás hacía que el input se viera negro sobre un modal blanco) — así
  # el modal se ve igual sin importar el theme, con el mismo acento
  # morado que usa el resto de la app.
  @campo_class "w-full rounded-lg border border-gray-300 bg-white px-3 py-2 text-sm text-gray-900 placeholder:text-gray-400 focus:border-purple-500 focus:outline-none focus:ring-2 focus:ring-purple-100"
  @boton_class "w-full rounded-lg bg-black hover:bg-gray-800 text-white font-semibold text-sm px-4 py-2.5 transition-colors disabled:opacity-60"

  # "Configuración de cuenta" pasó de ser una página aparte
  # (UsuarioLive.Settings) a este modal, embebido en menu_layout.ex y
  # disponible desde CUALQUIER pantalla admin sin tocar cada LiveView que
  # la usa — el componente maneja TODOS sus eventos vía phx-target={@myself},
  # así que el LiveView padre (BcListLive, CatalogoLive, etc.) no necesita
  # saber que esto existe.
  #
  # UsuarioLive.Settings exigía sudo mode (re-autenticación reciente) vía
  # on_mount ANTES de poder ver la página — acá no hay "mount" por
  # navegación, el modal ya está montado de arranque con el resto de la
  # página, así que el chequeo se hace al abrir (@sudo?) y los formularios
  # de email/contraseña se ocultan (con aviso) si no se cumple, en vez de
  # redirigir a toda la pantalla como hacía la página vieja.
  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign(:campo_class, @campo_class)
     |> assign(:boton_class, @boton_class)
     |> assign_new(:abierto, fn -> false end)
     |> assign_new(:alias_form, fn -> nil end)
     |> assign_new(:email_form, fn -> nil end)
     |> assign_new(:password_form, fn -> nil end)
     |> assign_new(:trigger_submit, fn -> false end)
     |> assign_new(:current_email, fn -> nil end)
     |> assign_new(:sudo?, fn -> false end)
     |> assign_new(:multiples_empresas?, fn -> false end)
     |> assign_new(:opciones_avatar, fn -> [] end)}
  end

  def handle_event("abrir", _params, socket) do
    usuario = socket.assigns.current_scope.usuario

    {:noreply,
     socket
     |> assign(:abierto, true)
     |> assign(:current_email, usuario.email)
     |> assign(:alias_form, to_form(Autenticacion.change_usuario_alias(usuario)))
     |> assign(:email_form, to_form(Autenticacion.change_usuario_email(usuario, %{}, validate_unique: false)))
     |> assign(:password_form, to_form(Autenticacion.change_usuario_password(usuario, %{}, hash_password: false)))
     |> assign(:trigger_submit, false)
     |> assign(:sudo?, Autenticacion.sudo_mode?(usuario, -10))
     |> assign(:multiples_empresas?, length(Autenticacion.empresas_de_usuario(usuario.id)) > 1)
     |> assign(:opciones_avatar, opciones_avatar_con_actual(usuario))}
  end

  def handle_event("cerrar", _params, socket) do
    {:noreply, assign(socket, :abierto, false)}
  end

  def handle_event("otras_opciones_avatar", _params, socket) do
    {:noreply, assign(socket, :opciones_avatar, Autenticacion.Usuario.semillas_avatar_al_azar(8))}
  end

  def handle_event("elegir_avatar", %{"seed" => seed}, socket) do
    case Autenticacion.update_usuario_avatar(socket.assigns.current_scope.usuario, %{"avatar_seed" => seed}) do
      {:ok, usuario} ->
        Notificaciones.crear(usuario.id, "Actualizaste tu avatar.")

        {:noreply,
         socket
         |> assign(:current_scope, %{socket.assigns.current_scope | usuario: usuario})
         |> put_flash(:info, "Avatar actualizado.")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "No se pudo actualizar el avatar.")}
    end
  end

  def handle_event("validate_alias", %{"usuario" => usuario_params}, socket) do
    alias_form =
      socket.assigns.current_scope.usuario
      |> Autenticacion.change_usuario_alias(usuario_params)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, alias_form: alias_form)}
  end

  def handle_event("update_alias", %{"usuario" => usuario_params}, socket) do
    case Autenticacion.update_usuario_alias(socket.assigns.current_scope.usuario, usuario_params) do
      {:ok, usuario} ->
        Notificaciones.crear(usuario.id, "Actualizaste tu alias a \"#{usuario.alias}\".")

        {:noreply,
         socket
         |> assign(:current_scope, %{socket.assigns.current_scope | usuario: usuario})
         |> assign(:alias_form, to_form(Autenticacion.change_usuario_alias(usuario)))
         |> put_flash(:info, "Alias actualizado.")}

      {:error, changeset} ->
        {:noreply, assign(socket, :alias_form, to_form(changeset, action: :insert))}
    end
  end

  def handle_event("validate_email", %{"usuario" => usuario_params}, socket) do
    email_form =
      socket.assigns.current_scope.usuario
      |> Autenticacion.change_usuario_email(usuario_params, validate_unique: false)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, email_form: email_form)}
  end

  def handle_event("update_email", %{"usuario" => usuario_params}, socket) do
    usuario = socket.assigns.current_scope.usuario

    if Autenticacion.sudo_mode?(usuario) do
      case Autenticacion.change_usuario_email(usuario, usuario_params) do
        %{valid?: true} = changeset ->
          Autenticacion.deliver_usuario_update_email_instructions(
            Ecto.Changeset.apply_action!(changeset, :insert),
            usuario.email,
            &url(~p"/meta_schema_usuario/settings/confirm-email/#{&1}")
          )

          info = "A link to confirm your email change has been sent to the new address."
          {:noreply, put_flash(socket, :info, info)}

        changeset ->
          {:noreply, assign(socket, :email_form, to_form(changeset, action: :insert))}
      end
    else
      {:noreply, assign(socket, :sudo?, false)}
    end
  end

  def handle_event("validate_password", %{"usuario" => usuario_params}, socket) do
    password_form =
      socket.assigns.current_scope.usuario
      |> Autenticacion.change_usuario_password(usuario_params, hash_password: false)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, password_form: password_form)}
  end

  def handle_event("update_password", %{"usuario" => usuario_params}, socket) do
    usuario = socket.assigns.current_scope.usuario

    if Autenticacion.sudo_mode?(usuario) do
      case Autenticacion.change_usuario_password(usuario, usuario_params) do
        %{valid?: true} = changeset ->
          {:noreply, assign(socket, trigger_submit: true, password_form: to_form(changeset))}

        changeset ->
          {:noreply, assign(socket, password_form: to_form(changeset, action: :insert))}
      end
    else
      {:noreply, assign(socket, :sudo?, false)}
    end
  end

  # Semillas al azar para elegir + la actual del usuario primero (si ya
  # tenía una elegida) — así al abrir el selector ve dónde está parado,
  # en vez de perder de vista su avatar actual entre 8 opciones nuevas.
  defp opciones_avatar_con_actual(usuario) do
    nuevas = Autenticacion.Usuario.semillas_avatar_al_azar(8)

    case usuario.avatar_seed do
      nil -> nuevas
      "" -> nuevas
      actual -> [actual | Enum.reject(nuevas, &(&1 == actual))] |> Enum.take(8)
    end
  end

  def render(assigns) do
    ~H"""
    <div id={@id}>
      <div :if={@abierto} class="fixed inset-0 bg-black/50 flex items-center justify-center z-[200] p-4">
        <div class="fixed inset-0" phx-click="cerrar" phx-target={@myself} />
        <div class="relative bg-white rounded-2xl shadow-2xl max-w-md w-full max-h-[85vh] overflow-y-auto">
          <!-- Header: avatar + nombre + correo, fondo negro — mismo acento
               que el sidebar y el login (ver menu.css/login.ex), no los
               colores de daisyUI que dependían del theme activo y quedaban
               inconsistentes. -->
          <div class="bg-black px-6 pt-6 pb-8 rounded-t-2xl relative">
            <button
              type="button"
              phx-click="cerrar"
              phx-target={@myself}
              class="absolute top-4 right-4 w-7 h-7 flex items-center justify-center rounded-lg text-white/70 hover:bg-white/10 hover:text-white transition-colors shrink-0"
            >
              <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
                <line x1="18" y1="6" x2="6" y2="18" /><line x1="6" y1="6" x2="18" y2="18" />
              </svg>
            </button>
            <div class="flex items-center gap-3">
              <img
                src={Autenticacion.Usuario.avatar_url(@current_scope.usuario, 96)}
                class="w-12 h-12 rounded-full bg-white/15 border border-white/25 shrink-0"
              />
              <div class="min-w-0">
                <h2 class="text-white font-bold text-base truncate">
                  {Autenticacion.Usuario.nombre_mostrar(@current_scope.usuario)}
                </h2>
                <p class="text-white/60 text-xs truncate">{@current_scope.usuario.email}</p>
              </div>
            </div>
          </div>

          <div class="px-6 py-5">
            <div :if={@multiples_empresas?} class="mb-4 -mt-2">
              <.link navigate={~p"/meta_schema_usuario/seleccionar-empresa"} class="text-sm text-purple-600 hover:text-purple-800 font-medium">
                Cambiar de empresa
              </.link>
            </div>

            <div class="flex items-center justify-between mb-2">
              <p class="text-[11px] font-bold uppercase tracking-wide text-gray-400">Avatar</p>
              <button
                type="button"
                phx-click="otras_opciones_avatar"
                phx-target={@myself}
                class="text-xs text-purple-600 hover:text-purple-800 font-medium"
              >
                Otras opciones
              </button>
            </div>
            <div class="grid grid-cols-4 gap-2 mb-5">
              <%= for semilla <- @opciones_avatar do %>
                <% elegido? = semilla == @current_scope.usuario.avatar_seed %>
                <button
                  type="button"
                  phx-click="elegir_avatar"
                  phx-value-seed={semilla}
                  phx-target={@myself}
                  title="Usar este avatar"
                  class={[
                    "aspect-square rounded-full overflow-hidden border-2 transition-colors",
                    if(elegido?, do: "border-purple-600 ring-2 ring-purple-200", else: "border-transparent hover:border-purple-300")
                  ]}
                >
                  <img src={Autenticacion.Usuario.avatar_url_desde_semilla(semilla, 96)} class="w-full h-full" />
                </button>
              <% end %>
            </div>

            <hr class="border-gray-200 my-5" />

            <p class="text-[11px] font-bold uppercase tracking-wide text-gray-400 mb-2">Alias</p>
            <.form for={@alias_form} id="modal_alias_form" phx-target={@myself} phx-submit="update_alias" phx-change="validate_alias" class="space-y-2">
              <.input
                field={@alias_form[:alias]}
                type="text"
                placeholder="Cómo querés que te muestre la barra superior"
                maxlength="40"
                class={@campo_class}
              />
              <.button class={@boton_class} phx-disable-with="Guardando...">Guardar alias</.button>
            </.form>

            <hr class="border-gray-200 my-5" />

            <%= if @sudo? do %>
              <p class="text-[11px] font-bold uppercase tracking-wide text-gray-400 mb-2">Email</p>
              <.form for={@email_form} id="modal_email_form" phx-target={@myself} phx-submit="update_email" phx-change="validate_email" class="space-y-2">
                <.input
                  field={@email_form[:email]}
                  type="email"
                  autocomplete="username"
                  spellcheck="false"
                  required
                  class={@campo_class}
                />
                <.button class={@boton_class} phx-disable-with="Changing...">Change Email</.button>
              </.form>

              <hr class="border-gray-200 my-5" />

              <p class="text-[11px] font-bold uppercase tracking-wide text-gray-400 mb-2">Contraseña</p>
              <.form
                for={@password_form}
                id="modal_password_form"
                action={~p"/meta_schema_usuario/update-password"}
                method="post"
                phx-target={@myself}
                phx-change="validate_password"
                phx-submit="update_password"
                phx-trigger-action={@trigger_submit}
                class="space-y-2"
              >
                <input
                  name={@password_form[:email].name}
                  type="hidden"
                  id="modal_hidden_usuario_email"
                  spellcheck="false"
                  value={@current_email}
                />
                <.input
                  field={@password_form[:password]}
                  type="password"
                  label="New password"
                  autocomplete="new-password"
                  spellcheck="false"
                  required
                  class={@campo_class}
                />
                <.input
                  field={@password_form[:password_confirmation]}
                  type="password"
                  label="Confirm new password"
                  autocomplete="new-password"
                  spellcheck="false"
                  class={@campo_class}
                />
                <.button class={@boton_class} phx-disable-with="Saving...">
                  Save Password
                </.button>
              </.form>
          <% else %>
              <div class="text-sm text-gray-500 bg-gray-50 border border-gray-200 rounded-lg p-3">
                Para cambiar tu email o contraseña necesitás volver a iniciar sesión (por seguridad).
                <.link href="/meta_schema_usuario/log-out" method="delete" class="text-purple-600 hover:text-purple-800 font-medium">
                  Cerrar sesión
                </.link>
              </div>
            <% end %>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
