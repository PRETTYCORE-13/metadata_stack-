defmodule MetadataAppWeb.UsuarioLive.Login do
  use MetadataAppWeb, :live_view

  alias MetadataApp.Autenticacion

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-sm space-y-4">
        <div class="text-center">
          <img
            src="https://prettycore.xyz/IMAGENES/Logo%20Prettycore%20(8).png"
            alt="Prettycore"
            class="mx-auto mb-4 h-12 w-auto"
          />
          <.header>
            <p class="text-white">Log in</p>
            <:subtitle :if={@current_scope}>
              <span class="text-white/60">You need to reauthenticate to perform sensitive actions on your account.</span>
            </:subtitle>
          </.header>
        </div>

        <div :if={local_mail_adapter?()} class="flex gap-3 rounded-lg border border-white/20 bg-white/5 p-4 text-white">
          <.icon name="hero-information-circle" class="size-6 shrink-0" />
          <div>
            <p>You are running the local mail adapter.</p>
            <p>
              To see sent emails, visit
              <.link href="/dev/mailbox" class="underline hover:text-white/80">the mailbox page</.link>.
            </p>
          </div>
        </div>

        <.form
          :let={f}
          for={@form}
          id="login_form_magic"
          action={~p"/meta_schema_usuario/log-in"}
          phx-submit="submit_magic"
        >
          <.input
            readonly={!!@current_scope}
            field={f[:email]}
            type="email"
            label="Email"
            autocomplete="username"
            spellcheck="false"
            required
            phx-mounted={JS.focus()}
            class="w-full input bg-black border-white/25 text-white placeholder:text-white/40 focus:border-white focus:outline-none"
          />
          <.button class="btn w-full bg-white text-black border-0 hover:bg-white/90">
            Log in with email <span aria-hidden="true">→</span>
          </.button>
        </.form>

        <div class="divider text-white/50 before:bg-white/15 after:bg-white/15">or</div>

        <.form
          :let={f}
          for={@form}
          id="login_form_password"
          action={~p"/meta_schema_usuario/log-in"}
          phx-submit="submit_password"
          phx-trigger-action={@trigger_submit}
        >
          <.input
            readonly={!!@current_scope}
            field={f[:email]}
            type="email"
            label="Email"
            autocomplete="username"
            spellcheck="false"
            required
            class="w-full input bg-black border-white/25 text-white placeholder:text-white/40 focus:border-white focus:outline-none"
          />
          <.input
            field={@form[:password]}
            type="password"
            label="Password"
            autocomplete="current-password"
            spellcheck="false"
            class="w-full input bg-black border-white/25 text-white placeholder:text-white/40 focus:border-white focus:outline-none"
          />
          <.button class="btn w-full bg-white text-black border-0 hover:bg-white/90">
            Log in <span aria-hidden="true">→</span>
          </.button>
        </.form>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    email =
      Phoenix.Flash.get(socket.assigns.flash, :email) ||
        get_in(socket.assigns, [:current_scope, Access.key(:usuario), Access.key(:email)])

    form = to_form(%{"email" => email}, as: "usuario")

    {:ok, assign(socket, form: form, trigger_submit: false)}
  end

  @impl true
  def handle_event("submit_password", _params, socket) do
    {:noreply, assign(socket, :trigger_submit, true)}
  end

  def handle_event("submit_magic", %{"usuario" => %{"email" => email}}, socket) do
    if usuario = Autenticacion.get_usuario_by_email(email) do
      Autenticacion.deliver_login_instructions(
        usuario,
        &url(~p"/meta_schema_usuario/log-in/#{&1}")
      )
    end

    info =
      "If your email is in our system, you will receive instructions for logging in shortly."

    {:noreply,
     socket
     |> put_flash(:info, info)
     |> push_navigate(to: ~p"/meta_schema_usuario/log-in")}
  end

  defp local_mail_adapter? do
    Application.get_env(:metadata_app, MetadataApp.Mailer)[:adapter] == Swoosh.Adapters.Local
  end
end
