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

  @ids_solo_bpb ["bc_list", "tepache"]

  @doc """
  Quita del menú lateral las entradas que dependen del Business Process
  Builder (no existe en producción, ver `bpb_habilitado`) cuando ese flag
  está apagado. Las pantallas de RBAC comparten el mismo `@menu` hardcodeado
  que las de BPB, así que sin este filtro sus sidebars mostrarían links a
  rutas que en un release de producción no existen. "Buscar TRN" quedó
  afuera de esta lista (2026-08-04, a pedido explícito): a diferencia del
  resto del BPB, no depende de ningún catálogo generado en caliente ni de
  código que no exista en un release — solo lee `meta_schema_transaction_registry`
  y los módulos de catálogo YA compilados, así que también vive en
  producción (ver la ruta correspondiente en el router, movida fuera del
  bloque `bpb_habilitado`).
  """
  def filtrar_menu(menu) do
    if Application.get_env(:metadata_app, :bpb_habilitado, false) do
      menu
    else
      Enum.reject(menu, &(&1.id in @ids_solo_bpb))
    end
  end

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
          nil -> {:noreply, socket}
          path -> {:noreply, push_navigate(socket, to: path)}
        end
    end
  end
end
