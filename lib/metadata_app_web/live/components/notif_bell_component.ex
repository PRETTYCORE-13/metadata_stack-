defmodule MetadataAppWeb.NotifBellComponent do
  use MetadataAppWeb, :live_component

  alias MetadataApp.Notificaciones

  # `count` es de NO LEÍDAS (badge) — se recalcula en cada update/2 (el
  # padre re-renderiza seguido, pero es un solo count() indexado, barato).
  # La lista de `notifications` recién se trae al abrir (toggle_notif),
  # no hace falta tenerla cargada todo el tiempo.
  def mount(socket) do
    {:ok, assign(socket, open: false, notifications: [], count: 0)}
  end

  def update(assigns, socket) do
    user_id = assigns[:user_id]
    count = if user_id, do: Notificaciones.contar_no_leidas(user_id), else: 0

    {:ok, assign(socket, user_id: user_id, count: count)}
  end

  def handle_event("toggle_notif", _, socket) do
    abrir? = !socket.assigns.open

    socket =
      if abrir? and socket.assigns.user_id do
        Notificaciones.marcar_todas_leidas(socket.assigns.user_id)

        socket
        |> assign(:notifications, Notificaciones.listar(socket.assigns.user_id))
        |> assign(:count, 0)
      else
        socket
      end

    {:noreply, assign(socket, :open, abrir?)}
  end

  def handle_event("cerrar_notif", _, socket) do
    {:noreply, assign(socket, :open, false)}
  end

  def render(assigns) do
    ~H"""
    <div class="relative flex items-center">
      <button
        phx-click="toggle_notif"
        phx-target={@myself}
        class="relative p-2 rounded-xl text-gray-500 hover:text-gray-800 hover:bg-gray-100 transition-colors"
        title="Notificaciones"
      >
        <svg class="w-5 h-5" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2">
          <path stroke-linecap="round" stroke-linejoin="round" d="M15 17h5l-1.405-1.405A2.032 2.032 0 0118 14.158V11a6.002 6.002 0 00-4-5.659V5a2 2 0 10-4 0v.341C7.67 6.165 6 8.388 6 11v3.159c0 .538-.214 1.055-.595 1.436L4 17h5m6 0v1a3 3 0 11-6 0v-1m6 0H9" />
        </svg>
        <%= if @count > 0 do %>
          <span class="absolute -top-0.5 -right-0.5 min-w-[16px] h-[16px] flex items-center justify-center bg-red-500 text-white text-[9px] font-bold rounded-full px-1 leading-none">
            <%= if @count > 99, do: "99+", else: @count %>
          </span>
        <% end %>
      </button>

      <%= if @open do %>
        <div
          class="fixed inset-0 z-[90]"
          phx-click="cerrar_notif"
          phx-target={@myself}
        />
        <div class="absolute right-0 top-full mt-2 w-80 bg-white rounded-2xl shadow-2xl border border-gray-100 z-[100] overflow-hidden">
          <div class="flex items-center justify-between px-4 py-3 border-b border-gray-100">
            <span class="text-sm font-bold text-gray-800">Notificaciones</span>
          </div>

          <div class="overflow-y-auto max-h-[360px] divide-y divide-gray-50">
            <%= if @notifications == [] do %>
              <div class="flex flex-col items-center justify-center py-12 text-gray-300">
                <svg class="w-12 h-12 mb-3" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="1">
                  <path stroke-linecap="round" stroke-linejoin="round" d="M15 17h5l-1.405-1.405A2.032 2.032 0 0118 14.158V11a6.002 6.002 0 00-4-5.659V5a2 2 0 10-4 0v.341C7.67 6.165 6 8.388 6 11v3.159c0 .538-.214 1.055-.595 1.436L4 17h5m6 0v1a3 3 0 11-6 0v-1m6 0H9" />
                </svg>
                <p class="text-xs font-medium">Sin notificaciones</p>
              </div>
            <% else %>
              <div :for={notif <- @notifications} class="flex items-start gap-2.5 px-4 py-3 hover:bg-gray-50">
                <span class={[
                  "mt-1 w-1.5 h-1.5 rounded-full shrink-0",
                  case notif.tipo do
                    "error" -> "bg-red-500"
                    "success" -> "bg-green-500"
                    _ -> "bg-purple-500"
                  end
                ]} />
                <div class="min-w-0">
                  <p class="text-xs text-gray-700 leading-snug">{notif.mensaje}</p>
                  <p class="text-[10px] text-gray-400 mt-0.5">{hace_cuanto(notif.inserted_at)}</p>
                </div>
              </div>
            <% end %>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  defp hace_cuanto(inserted_at) do
    segundos = DateTime.diff(DateTime.utc_now(), inserted_at)

    cond do
      segundos < 60 -> "ahora"
      segundos < 3600 -> "hace #{div(segundos, 60)} min"
      segundos < 86_400 -> "hace #{div(segundos, 3600)} h"
      true -> "hace #{div(segundos, 86_400)} d"
    end
  end
end
