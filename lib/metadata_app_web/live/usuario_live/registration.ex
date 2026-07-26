defmodule MetadataAppWeb.UsuarioLive.Registration do
  use MetadataAppWeb, :live_view

  alias MetadataApp.Autenticacion
  alias MetadataApp.Autenticacion.Usuario

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-sm">
        <div class="text-center">
          <.header>
            Register for an account
            <:subtitle>
              Already registered?
              <.link navigate={~p"/meta_schema_usuario/log-in"} class="font-semibold text-brand hover:underline">
                Log in
              </.link>
              to your account now.
            </:subtitle>
          </.header>
        </div>

        <.form for={@form} id="registration_form" phx-submit="save" phx-change="validate">
          <.input
            field={@form[:email]}
            type="email"
            label="Email"
            autocomplete="username"
            spellcheck="false"
            required
            phx-mounted={JS.focus()}
          />

          <.button phx-disable-with="Creating account..." class="btn btn-primary w-full">
            Create an account
          </.button>
        </.form>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, %{assigns: %{current_scope: %{usuario: usuario}}} = socket)
      when not is_nil(usuario) do
    {:ok, redirect(socket, to: MetadataAppWeb.UsuarioAuth.signed_in_path(socket))}
  end

  def mount(_params, _session, socket) do
    changeset = Autenticacion.change_usuario_email(%Usuario{}, %{}, validate_unique: false)

    {:ok, assign_form(socket, changeset), temporary_assigns: [form: nil]}
  end

  @impl true
  def handle_event("save", %{"usuario" => usuario_params}, socket) do
    case Autenticacion.register_usuario(usuario_params) do
      {:ok, usuario} ->
        {:ok, _} =
          Autenticacion.deliver_login_instructions(
            usuario,
            &url(~p"/meta_schema_usuario/log-in/#{&1}")
          )

        {:noreply,
         socket
         |> put_flash(
           :info,
           "An email was sent to #{usuario.email}, please access it to confirm your account."
         )
         |> push_navigate(to: ~p"/meta_schema_usuario/log-in")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  def handle_event("validate", %{"usuario" => usuario_params}, socket) do
    changeset = Autenticacion.change_usuario_email(%Usuario{}, usuario_params, validate_unique: false)
    {:noreply, assign_form(socket, Map.put(changeset, :action, :validate))}
  end

  defp assign_form(socket, %Ecto.Changeset{} = changeset) do
    form = to_form(changeset, as: "usuario")
    assign(socket, form: form)
  end
end
