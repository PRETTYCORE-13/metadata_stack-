defmodule MetadataAppWeb.Layouts do
  import MetadataAppWeb.MenuLayout

  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use MetadataAppWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://hexdocs.pm/phoenix/scopes.html)"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <div class="min-h-screen flex flex-col bg-black text-white">
      <header class="navbar px-4 sm:px-6 lg:px-8 flex-wrap gap-y-2 border-b border-white/10">
        <div class="flex-1">
          <a href="/" class="flex-1 flex w-fit items-center gap-2">
            <img src="https://prettycore.xyz/IMAGENES/Logo%20Prettycore%20(8).png" alt="Prettycore" class="h-9 w-auto" />
          </a>
        </div>
        <!-- min-w-0 + sm:flex-none (en vez de flex-none a secas): flex-none
             bloquea el shrink del contenedor sin importar cuánto lo empuje
             el flex-wrap de arriba — el <ul> de adentro nunca llegaba a
             angostarse lo suficiente como para que SU PROPIO flex-wrap
             entrara a tallar, y se salía del viewport en un celular. Bajo
             sm (640px) sí hay lugar de sobra para el comportamiento
             original de una sola fila sin crecer/achicarse. -->
        <div class="min-w-0 sm:flex-none">
          <ul class="flex flex-wrap px-1 gap-4 items-center justify-end">
            <li>
              <a href="https://phoenixframework.org/" class="btn btn-ghost text-white hover:bg-white/10">Website</a>
            </li>
            <li>
              <a href="https://github.com/phoenixframework/phoenix" class="btn btn-ghost text-white hover:bg-white/10">
                GitHub
              </a>
            </li>
            <li>
              <.theme_toggle />
            </li>
            <li>
              <a
                href="https://hexdocs.pm/phoenix/overview.html"
                class="btn bg-white text-black border-0 hover:bg-white/90"
              >
                Get Started <span aria-hidden="true">&rarr;</span>
              </a>
            </li>
          </ul>
        </div>
      </header>

      <main class="flex-1 px-4 py-20 sm:px-6 lg:px-8">
        <div class="mx-auto max-w-2xl space-y-4">
          {render_slot(@inner_block)}
        </div>
      </main>

      <.flash_group flash={@flash} />
    </div>
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title="No se encuentra conexión a internet"
        phx-disconnected={show(".phx-client-error #client-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        Intentando reconectar
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title="¡Algo salió mal!"
        phx-disconnected={show(".phx-server-error #server-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        Intentando reconectar
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="card relative flex flex-row items-center border-2 border-base-300 bg-base-300 rounded-full">
      <div class="absolute w-1/3 h-full rounded-full border-1 border-base-200 bg-base-100 brightness-200 left-0 [[data-theme=light]_&]:left-1/3 [[data-theme=dark]_&]:left-2/3 transition-[left]" />

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
      >
        <.icon name="hero-sun-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
      >
        <.icon name="hero-moon-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end
end
