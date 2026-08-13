defmodule MetadataAppWeb.UsuarioLive.Confirmation do
  use MetadataAppWeb, :live_view

  alias MetadataApp.Autenticacion

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-sm">
        <div class="text-center">
          <.header>Welcome {@usuario.email}</.header>
        </div>

        <.form
          :if={!@usuario.confirmed_at}
          for={@form}
          id="confirmation_form"
          phx-mounted={JS.focus_first()}
          phx-submit="submit"
          action={~p"/meta_schema_usuario/log-in?_action=confirmed"}
          phx-trigger-action={@trigger_submit}
        >
          <input type="hidden" name={@form[:token].name} value={@form[:token].value} />
          <.button phx-disable-with="Confirming..." class="btn btn-primary w-full">
            Confirm
          </.button>
        </.form>

        <.form
          :if={@usuario.confirmed_at}
          for={@form}
          id="login_form"
          phx-submit="submit"
          phx-mounted={JS.focus_first()}
          action={~p"/meta_schema_usuario/log-in"}
          phx-trigger-action={@trigger_submit}
        >
          <input type="hidden" name={@form[:token].name} value={@form[:token].value} />
          <.button phx-disable-with="Logging in..." class="btn btn-primary w-full">
            Log in
          </.button>
        </.form>

        <p :if={!@usuario.confirmed_at} class="alert alert-outline mt-8">
          Tip: If you prefer passwords, you can enable them in the usuario settings.
        </p>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    if usuario = Autenticacion.get_usuario_by_magic_link_token(token) do
      form = to_form(%{"token" => token}, as: "usuario")

      {:ok, assign(socket, usuario: usuario, form: form, trigger_submit: false),
       temporary_assigns: [form: nil]}
    else
      {:ok,
       socket
       |> put_flash(:error, "Magic link is invalid or it has expired.")
       |> push_navigate(to: ~p"/meta_schema_usuario/log-in")}
    end
  end

  @impl true
  def handle_event("submit", %{"usuario" => params}, socket) do
    {:noreply, assign(socket, form: to_form(params, as: "usuario"), trigger_submit: true)}
  end
end
