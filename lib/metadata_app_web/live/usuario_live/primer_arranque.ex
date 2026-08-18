defmodule MetadataAppWeb.UsuarioLive.PrimerArranque do
  @moduledoc """
  Wizard de primer arranque (docs/onboarding-nuevo-sistema.md, Fase 2) —
  la contraparte web de `MetadataApp.Release.setup/0`. Mientras no exista
  NINGÚN sysadmin, `MetadataAppWeb.RequierePrimerArranque` (plug en el
  pipeline :browser) redirige acá cualquier request — así Operaciones
  completa un sistema nuevo desde el navegador, sin SSH, sin inventar
  una contraseña por variable de entorno para cada uno de ~100 sistemas.

  Reusa `Autenticacion.upsert_sysadmin/2` + `crear_empresa_para_usuario/2`
  tal cual — las mismas funciones que ya usa `Release.setup/0` — no hay
  lógica de creación nueva acá, solo el formulario.

  Tras crear todo, dispara un POST real (phx-trigger-action, mismo
  patrón que UsuarioLive.Login) contra el login por contraseña ya
  existente — así la sesión se establece con la infraestructura real de
  cookies/tokens, no algo aparte inventado para el wizard.
  """
  use MetadataAppWeb, :live_view

  alias MetadataApp.Autenticacion

  @impl true
  def mount(_params, _session, socket) do
    # Guard: si ya existe un sysadmin (alguien más lo completó mientras
    # esta pestaña estaba abierta, o el plug tenía el :persistent_term
    # desactualizado por un momento), no hay wizard que mostrar -- a
    # login. Nunca se puede usar esto para crear un SEGUNDO sysadmin.
    if Autenticacion.existe_sysadmin?() do
      {:ok, push_navigate(socket, to: ~p"/meta_schema_usuario/log-in")}
    else
      # as: "usuario" a propósito, no "arranque" -- el POST real que
      # dispara phx-trigger-action al final va contra
      # UsuarioSessionController.create/2, que espera usuario[email]/
      # usuario[password]. nombre_empresa/password_confirmation viajan
      # de más ahí (el controller los ignora, hace pattern match solo de
      # lo que necesita) -- más simple que reasignar el form justo antes
      # de disparar el submit.
      form =
        to_form(%{"email" => "", "password" => "", "password_confirmation" => "", "nombre_empresa" => ""}, as: "usuario")

      {:ok,
       socket
       |> assign(:form, form)
       |> assign(:error, nil)
       |> assign(:procesando?, false)
       |> assign(:trigger_submit, false)}
    end
  end

  @impl true
  def handle_event("guardar", %{"usuario" => params}, socket) do
    with :ok <- validar(params),
         {:ok, usuario} <- Autenticacion.upsert_sysadmin(params["email"], params["password"]),
         {:ok, _empresa} <- Autenticacion.crear_empresa_para_usuario(params["nombre_empresa"], usuario.id) do
      {:noreply,
       socket
       |> assign(:form, to_form(params, as: "usuario"))
       |> assign(:trigger_submit, true)}
    else
      {:error, mensaje} when is_binary(mensaje) ->
        {:noreply, assign(socket, :error, mensaje)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :error, mensaje_de_changeset(changeset))}
    end
  end

  defp validar(params) do
    cond do
      params["email"] in [nil, ""] -> {:error, "Falta el correo del administrador."}
      params["password"] in [nil, ""] -> {:error, "Falta la contraseña."}
      params["password"] != params["password_confirmation"] -> {:error, "Las contraseñas no coinciden."}
      String.length(params["password"]) < 12 -> {:error, "La contraseña necesita al menos 12 caracteres."}
      params["nombre_empresa"] in [nil, ""] -> {:error, "Falta el nombre de la empresa."}
      true -> :ok
    end
  end

  defp mensaje_de_changeset(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, _opts} -> msg end)
    |> Enum.flat_map(fn {_campo, mensajes} -> mensajes end)
    |> Enum.join(", ")
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="mx-auto max-w-sm space-y-4">
        <div class="text-center">
          <img
            src="https://prettycore.xyz/IMAGENES/Logo%20Prettycore%20(8).png"
            alt="Prettycore"
            class="mx-auto mb-4 h-12 w-auto"
          />
          <.header>
            <p class="text-white">Configurá tu sistema</p>
            <:subtitle>
              <span class="text-white/60">Primer arranque — creá el administrador y la empresa inicial.</span>
            </:subtitle>
          </.header>
        </div>

        <div :if={@error} class="rounded-lg border border-red-400/40 bg-red-500/10 p-3 text-sm text-red-200">
          {@error}
        </div>

        <.form
          :let={f}
          for={@form}
          id="primer_arranque_form"
          action={~p"/meta_schema_usuario/log-in"}
          phx-submit="guardar"
          phx-trigger-action={@trigger_submit}
        >
          <.input
            field={f[:nombre_empresa]}
            type="text"
            label="Nombre de la empresa"
            required
            phx-mounted={JS.focus()}
            class="w-full input bg-black border-white/25 text-white placeholder:text-white/40 focus:border-white focus:outline-none"
          />
          <.input
            field={f[:email]}
            type="email"
            label="Correo del administrador"
            autocomplete="username"
            spellcheck="false"
            required
            class="w-full input bg-black border-white/25 text-white placeholder:text-white/40 focus:border-white focus:outline-none"
          />
          <.input
            field={f[:password]}
            type="password"
            label="Contraseña (mínimo 12 caracteres)"
            autocomplete="new-password"
            required
            class="w-full input bg-black border-white/25 text-white placeholder:text-white/40 focus:border-white focus:outline-none"
          />
          <.input
            field={f[:password_confirmation]}
            type="password"
            label="Confirmar contraseña"
            autocomplete="new-password"
            required
            class="w-full input bg-black border-white/25 text-white placeholder:text-white/40 focus:border-white focus:outline-none"
          />
          <.button class="btn w-full bg-white text-black border-0 hover:bg-white/90">
            Crear y entrar <span aria-hidden="true">→</span>
          </.button>
        </.form>
      </div>
    </Layouts.app>
    """
  end
end
