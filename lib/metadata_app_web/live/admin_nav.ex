defmodule MetadataAppWeb.AdminNav do
  @moduledoc """
  Handler centralizado de navegación admin.
  Un solo lugar para mantener todas las rutas del menú lateral.
  """

  import Phoenix.LiveView, only: [push_navigate: 2]
  import Phoenix.Component, only: [update: 3]

  @routes %{
    "inicio"    => "/",
    "tienda"    => "/",
    "pedidos"   => "/",
    "disenador" => "/",
    "usuarios"  => "/"
  }

  @doc """
  Maneja el evento change_page. `current_page` es el atom/string de la página actual
  para evitar navegar a la misma URL (causaría remount).
  """
  def handle_nav(id, socket, current_page \\ nil) do
    case id do
      "toggle_sidebar" ->
        {:noreply, update(socket, :sidebar_open, &(not &1))}

      page when page == current_page ->
        {:noreply, socket}

      other ->
        case Map.get(@routes, other) do
          nil  -> {:noreply, socket}
          path -> {:noreply, push_navigate(socket, to: path)}
        end
    end
  end
end
