defmodule MetadataAppWeb.InicioLive do
  use MetadataAppWeb, :live_view_admin

  alias MetadataAppWeb.AdminNav

  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:current_page, "inicio")
     |> assign(:sidebar_open, false)
     |> assign(:show_programacion_children, false)
     |> assign(:show_clientes_children, false)
     |> assign(:show_prettycore_children, false)}
  end

  def handle_event("change_page", %{"id" => id}, socket) do
    AdminNav.handle_nav(id, socket, "inicio")
  end

  def render(assigns) do
    ~H"""
    <div class="p-8">
      <h1 class="text-2xl font-bold">Bienvenido</h1>
    </div>
    """
  end
end
