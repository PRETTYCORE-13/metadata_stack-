defmodule MetadataAppWeb.Sysadmin.BcListLive do
  use MetadataAppWeb, :live_view_admin

  alias MetadataApp.BusinessProcessBuilder.CatalogoGenerador
  alias MetadataApp.BusinessProcessBuilder.MetaSchemaContext
  alias MetadataAppWeb.AdminNav

  @topic "bc_contextos"
  @por_pagina 50

  # Menú hardcodeado del perfil sysadmin — todavía no hay login, así que
  # esta pantalla es de acceso directo. Según se agreguen secciones, se
  # suman aquí (por ahora solo "BC List").
  @menu [
    %{tipo: :pagina, id: "bc_list", label: "BC List", nav: "/sysadmin/bc-list"}
  ]

  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(MetadataApp.PubSub, @topic)

    {:ok,
     socket
     |> assign(:current_page, "bc_list")
     |> assign(:menu_items, @menu)
     |> assign(:sidebar_open, false)
     |> assign(:show_programacion_children, false)
     |> assign(:show_clientes_children, false)


     |> assign(:show_prettycore_children, false)
     |> assign(:busqueda, "")
     |> assign(:pagina, 1)
     |> assign(:carpetas_colapsadas, MapSet.new())
     |> assign(:accion_eliminar, nil)
     |> cargar_headers()}
  end

  def handle_event("change_page", %{"id" => id}, socket) do
    AdminNav.handle_nav(id, socket, "bc_list")
  end

  # Cada búsqueda nueva arranca desde la página 1 — si no, podrías quedar
  # parado en una página que ya ni existe con los resultados filtrados.
  def handle_event("buscar", %{"value" => valor}, socket) do
    {:noreply, socket |> assign(:busqueda, valor) |> assign(:pagina, 1) |> cargar_headers()}
  end

  def handle_event("pagina_anterior", _params, socket) do
    {:noreply, socket |> assign(:pagina, max(socket.assigns.pagina - 1, 1)) |> cargar_headers()}
  end

  def handle_event("pagina_siguiente", _params, socket) do
    {:noreply, socket |> assign(:pagina, socket.assigns.pagina + 1) |> cargar_headers()}
  end

  # Colapsar/expandir un grupo de la tabla — estado solo de esta pantalla
  # (no se guarda en el servidor entre sesiones, se resetea al recargar).
  def handle_event("toggle_carpeta", %{"ruta" => ruta}, socket) do
    colapsadas = socket.assigns.carpetas_colapsadas

    colapsadas =
      if MapSet.member?(colapsadas, ruta) do
        MapSet.delete(colapsadas, ruta)
      else
        MapSet.put(colapsadas, ruta)
      end

    {:noreply, assign(socket, :carpetas_colapsadas, colapsadas)}
  end

  # Paso 1 del borrado: consulta el impacto antes de mostrar cualquier
  # confirmación. Si hay dependientes, el borrado real va a fallar seguro
  # (validar_sin_dependientes en CatalogoGenerador.eliminar/3) — se corta acá
  # con un mensaje explicativo en vez de dejar avanzar a un confirm que
  # después explota.
  def handle_event("pedir_eliminar", %{"tabla" => tabla, "label" => label}, socket) do
    case CatalogoGenerador.impacto(tabla) do
      {:ok, %{dependientes: []} = resultado} ->
        {:noreply,
         assign(socket, :accion_eliminar, %{
           tipo: :confirmar,
           tabla: tabla,
           label: label,
           filas: resultado.filas
         })}

      {:ok, %{dependientes: dependientes}} ->
        {:noreply,
         assign(socket, :accion_eliminar, %{
           tipo: :bloqueado,
           tabla: tabla,
           label: label,
           dependientes: dependientes
         })}

      {:error, _motivo} ->
        {:noreply, put_flash(socket, :error, "No se pudo consultar el catálogo #{tabla}.")}
    end
  end

  def handle_event("cancelar_eliminar", _params, socket) do
    {:noreply, assign(socket, :accion_eliminar, nil)}
  end

  # Una carpeta no tiene tabla ni filas que perder — a diferencia de
  # "pedir_eliminar" (archivo), acá no hay que consultar impacto/1 primero,
  # solo confirmar. Borrar la carpeta no toca a sus hijos: solo pierden la
  # etiqueta/ícono personalizados y el segmento vuelve a mostrarse con el
  # nombre crudo de la ruta (ver construir_arbol/1).
  def handle_event("pedir_eliminar_carpeta", %{"nombre" => nombre, "label" => label}, socket) do
    {:noreply, assign(socket, :accion_eliminar, %{tipo: :confirmar_carpeta, nombre: nombre, label: label})}
  end

  def handle_event("confirmar_eliminar_carpeta", _params, socket) do
    %{nombre: nombre} = socket.assigns.accion_eliminar

    case MetaSchemaContext.obtener_header_por_nombre(nombre) do
      nil ->
        {:noreply,
         socket
         |> assign(:accion_eliminar, nil)
         |> put_flash(:error, "Esa carpeta ya no existe.")}

      header ->
        case MetaSchemaContext.eliminar_header(header) do
          :ok ->
            {:noreply,
             socket
             |> assign(:accion_eliminar, nil)
             |> put_flash(:info, "Carpeta #{header.schema_context_label} eliminada.")
             |> cargar_headers()}

          {:error, motivo} ->
            {:noreply,
             socket
             |> assign(:accion_eliminar, nil)
             |> put_flash(:error, "No se pudo eliminar: #{inspect(motivo)}")}
        end
    end
  end

  # confirmar_filas viaja como el número ya conocido del paso de impacto (no
  # se le vuelve a pedir al usuario que lo tipee) — sigue siendo una
  # confirmación real porque valida contra el conteo actual en el momento del
  # borrado, no el de cuando se abrió el modal.
  def handle_event("confirmar_eliminar", _params, socket) do
    %{tabla: tabla, filas: filas} = socket.assigns.accion_eliminar

    case CatalogoGenerador.eliminar(tabla, tabla, filas) do
      {:ok, _resultado} ->
        {:noreply,
         socket
         |> assign(:accion_eliminar, nil)
         |> put_flash(:info, "Catálogo #{tabla} eliminado.")
         |> cargar_headers()}

      {:error, motivo} ->
        {:noreply,
         socket
         |> assign(:accion_eliminar, nil)
         |> put_flash(:error, "No se pudo eliminar #{tabla}: #{inspect(motivo)}")}
    end
  end

  # El formulario de creación (BcNuevoLive) y el de edición de carpeta
  # (BcEditarCarpetaLive) avisan por PubSub al terminar de guardar, así
  # esta lista se refresca sola sin que el usuario recargue.
  def handle_info({:bc_creado, _header}, socket) do
    {:noreply, cargar_headers(socket)}
  end

  def handle_info({:bc_actualizado, _header}, socket) do
    {:noreply, cargar_headers(socket)}
  end

  # Se pagina la lista PLANA (antes de armar el árbol) — por eso una carpeta
  # puede aparecer "incompleta" en una página y seguir en la siguiente, es el
  # trade-off normal de paginar algo que se agrupa después. Con @por_pagina
  # bastante alto (50) esto casi no se nota en la práctica.
  defp cargar_headers(socket) do
    filtrados =
      MetaSchemaContext.listar_headers()
      |> Enum.map(&MetaSchemaContext.item_de_header/1)
      |> Enum.filter(&coincide_busqueda?(&1, socket.assigns.busqueda))

    total_items = length(filtrados)
    total_paginas = max(ceil(total_items / @por_pagina), 1)
    pagina = socket.assigns.pagina |> max(1) |> min(total_paginas)

    arbol =
      filtrados
      |> Enum.slice((pagina - 1) * @por_pagina, @por_pagina)
      |> MetaSchemaContext.construir_arbol()

    socket
    |> assign(:arbol, arbol)
    |> assign(:pagina, pagina)
    |> assign(:total_paginas, total_paginas)
    |> assign(:total_items, total_items)
  end

  defp coincide_busqueda?(_item, ""), do: true

  defp coincide_busqueda?(item, busqueda) do
    objetivo = normalizar_busqueda(item.label) <> " " <> normalizar_busqueda(item.id)
    String.contains?(objetivo, normalizar_busqueda(busqueda))
  end

  defp normalizar_busqueda(texto) do
    texto
    |> String.downcase()
    |> String.normalize(:nfd)
    |> String.replace(~r/\p{Mn}/u, "")
  end

  def render(assigns) do
    ~H"""
    <div class="max-w-5xl mx-auto p-8">
      <div class="flex items-center justify-between mb-4">
        <h1 class="text-2xl font-bold">BC List</h1>
        <button
          type="button"
          id="btn-nuevo-contexto"
          phx-hook="AbrirVentana"
          data-url="/sysadmin/bc-list/nuevo"
          class="bg-purple-600 hover:bg-purple-700 text-white font-bold px-6 py-2 rounded"
        >
          + Nuevo
        </button>
      </div>

      <div class="mb-4">
        <input
          type="text"
          value={@busqueda}
          phx-keyup="buscar"
          phx-debounce="200"
          placeholder="Buscar por nombre o etiqueta..."
          class="w-full border border-gray-300 rounded-lg px-4 py-2 text-sm text-gray-900"
        />
      </div>

      <div class="overflow-x-auto rounded-xl border border-gray-200">
        <table class="min-w-full divide-y divide-gray-200 text-sm">
          <thead class="bg-gray-50">
            <tr>
              <th class="px-4 py-2 text-left font-semibold text-gray-600">Nombre de sistema</th>
              <th class="px-4 py-2 text-left font-semibold text-gray-600">Etiqueta</th>
              <th class="px-4 py-2 text-left font-semibold text-gray-600">Navegación</th>
              <th class="px-4 py-2 text-left font-semibold text-gray-600">Es visible</th>
              <th class="px-4 py-2 text-left font-semibold text-gray-600">Acciones</th>
            </tr>
          </thead>
          <tbody class="divide-y divide-gray-100">
            <.filas_arbol nodos={@arbol} carpetas_colapsadas={@carpetas_colapsadas} />
            <%= if @arbol == [] do %>
              <tr>
                <td class="px-4 py-6 text-center text-gray-400" colspan="5">
                  {if @busqueda == "", do: "Todavía no hay contextos creados", else: "Sin resultados para \"#{@busqueda}\""}
                </td>
              </tr>
            <% end %>
          </tbody>
        </table>
      </div>

      <%= if @total_paginas > 1 do %>
        <div class="flex items-center justify-between mt-4 text-sm text-gray-600">
          <span>
            Página {@pagina} de {@total_paginas} ({@total_items} en total)
          </span>
          <div class="flex gap-2">
            <button
              type="button"
              phx-click="pagina_anterior"
              disabled={@pagina <= 1}
              class="px-3 py-1.5 rounded border border-gray-300 disabled:opacity-40 disabled:cursor-not-allowed hover:bg-gray-50"
            >
              ← Anterior
            </button>
            <button
              type="button"
              phx-click="pagina_siguiente"
              disabled={@pagina >= @total_paginas}
              class="px-3 py-1.5 rounded border border-gray-300 disabled:opacity-40 disabled:cursor-not-allowed hover:bg-gray-50"
            >
              Siguiente →
            </button>
          </div>
        </div>
      <% end %>
    </div>

    <.modal_eliminar accion={@accion_eliminar} />
    """
  end

  # Modal de confirmación de borrado — dos variantes según lo que haya
  # contestado CatalogoGenerador.impacto/1 en "pedir_eliminar":
  # :confirmar (sin dependientes, puede seguir) o :bloqueado (hay otro
  # catálogo referenciando a este, no tiene sentido ofrecer continuar).
  attr :accion, :map, default: nil

  defp modal_eliminar(%{accion: nil} = assigns), do: ~H""

  defp modal_eliminar(%{accion: %{tipo: :confirmar}} = assigns) do
    ~H"""
    <div class="fixed inset-0 bg-black/40 flex items-center justify-center z-50">
      <div class="bg-white rounded-xl shadow-lg max-w-md w-full p-6">
        <h2 class="text-lg font-bold text-gray-900 mb-2">Eliminar catálogo</h2>
        <p class="text-sm text-gray-700 mb-6">
          Se eliminará el catálogo <strong>{@accion.label}</strong> ({@accion.tabla}) —
          <strong>{@accion.filas}</strong> fila(s). Este proceso no es reversible. ¿Desea continuar?
        </p>
        <div class="flex justify-end gap-3">
          <button
            type="button"
            phx-click="cancelar_eliminar"
            class="px-4 py-2 rounded border border-gray-300 text-gray-700 text-sm font-semibold hover:bg-gray-50"
          >
            Cancelar
          </button>
          <button
            type="button"
            phx-click="confirmar_eliminar"
            class="px-4 py-2 rounded bg-red-600 text-white text-sm font-semibold hover:bg-red-700"
          >
            Eliminar
          </button>
        </div>
      </div>
    </div>
    """
  end

  defp modal_eliminar(%{accion: %{tipo: :confirmar_carpeta}} = assigns) do
    ~H"""
    <div class="fixed inset-0 bg-black/40 flex items-center justify-center z-50">
      <div class="bg-white rounded-xl shadow-lg max-w-md w-full p-6">
        <h2 class="text-lg font-bold text-gray-900 mb-2">Eliminar carpeta</h2>
        <p class="text-sm text-gray-700 mb-6">
          Se eliminará la carpeta <strong>{@accion.label}</strong> del menú. Los catálogos que
          ya están adentro NO se borran — solo pierden esta etiqueta/ícono personalizados y
          la carpeta vuelve a mostrarse con el nombre de la ruta. ¿Desea continuar?
        </p>
        <div class="flex justify-end gap-3">
          <button
            type="button"
            phx-click="cancelar_eliminar"
            class="px-4 py-2 rounded border border-gray-300 text-gray-700 text-sm font-semibold hover:bg-gray-50"
          >
            Cancelar
          </button>
          <button
            type="button"
            phx-click="confirmar_eliminar_carpeta"
            class="px-4 py-2 rounded bg-red-600 text-white text-sm font-semibold hover:bg-red-700"
          >
            Eliminar
          </button>
        </div>
      </div>
    </div>
    """
  end

  defp modal_eliminar(%{accion: %{tipo: :bloqueado}} = assigns) do
    ~H"""
    <div class="fixed inset-0 bg-black/40 flex items-center justify-center z-50">
      <div class="bg-white rounded-xl shadow-lg max-w-md w-full p-6">
        <h2 class="text-lg font-bold text-gray-900 mb-2">No se puede eliminar</h2>
        <p class="text-sm text-gray-700 mb-6">
          Hay otro catálogo con un campo "referencia" apuntando a este ({Enum.join(@accion.dependientes, ", ")}).
          Hay que borrar o desenganchar esos primero.
        </p>
        <div class="flex justify-end">
          <button
            type="button"
            phx-click="cancelar_eliminar"
            class="px-4 py-2 rounded bg-purple-600 text-white text-sm font-semibold hover:bg-purple-700"
          >
            Aceptar
          </button>
        </div>
      </div>
    </div>
    """
  end

  # Filas de la tabla agrupadas igual que el menú: una fila de encabezado
  # gris por carpeta, recursivo para soportar carpetas anidadas.
  attr :nodos, :list, required: true
  attr :nivel, :integer, default: 0

  attr :carpetas_colapsadas, :any, default: MapSet.new()
  attr :ruta_padre, :string, default: ""

  def filas_arbol(assigns) do
    ~H"""
    <%= for nodo <- @nodos do %>
      <%= if nodo.tipo == :carpeta do %>
        <% ruta = if @ruta_padre == "", do: nodo.segmento, else: @ruta_padre <> "/" <> nodo.segmento %>
        <% colapsada? = MapSet.member?(@carpetas_colapsadas, ruta) %>
        <tr class="bg-gray-50 hover:bg-gray-100">
          <td
            colspan="5"
            class="px-4 py-1.5 text-xs select-none"
            style={"padding-left: #{16 + @nivel * 20}px"}
          >
            <div class="flex items-center justify-between gap-2">
              <button
                type="button"
                phx-click="toggle_carpeta"
                phx-value-ruta={ruta}
                class="flex items-center gap-1 font-semibold text-gray-500 uppercase tracking-wide cursor-pointer flex-1 text-left"
              >
                <span class="inline-block w-3">{if colapsada?, do: "▸", else: "▾"}</span>
                📁 {nodo.nombre}
              </button>
              <%= if nodo.id do %>
                <div class="flex gap-2 normal-case tracking-normal flex-shrink-0">
                  <button
                    type="button"
                    id={"btn-editar-carpeta-#{nodo.id}"}
                    phx-hook="AbrirVentana"
                    data-url={"/sysadmin/bc-list/carpeta/#{nodo.id}/editar"}
                    class="text-blue-600 hover:text-blue-800 text-xs font-semibold"
                  >
                    Editar
                  </button>
                  <button
                    type="button"
                    phx-click="pedir_eliminar_carpeta"
                    phx-value-nombre={nodo.id}
                    phx-value-label={nodo.nombre}
                    class="text-red-600 hover:text-red-800 text-xs font-semibold"
                  >
                    Eliminar
                  </button>
                </div>
              <% end %>
            </div>
          </td>
        </tr>
        <%= if !colapsada? do %>
          <.filas_arbol nodos={nodo.hijos} nivel={@nivel + 1} carpetas_colapsadas={@carpetas_colapsadas} ruta_padre={ruta} />
        <% end %>
      <% else %>
        <tr>
          <td class="px-4 py-2 text-gray-800" style={"padding-left: #{16 + @nivel * 20}px"}>{nodo.id}</td>
          <td class="px-4 py-2 text-gray-800">{nodo.label}</td>
          <td class="px-4 py-2 text-gray-800">{nodo.nav}</td>
          <td class="px-4 py-2 text-gray-800">{if nodo.visible, do: "Sí", else: "No"}</td>
          <td class="px-4 py-2">
            <div class="flex gap-2">
              <button type="button" class="text-blue-600 hover:text-blue-800 text-xs font-semibold">
                Editar
              </button>
              <button
                type="button"
                phx-click="pedir_eliminar"
                phx-value-tabla={nodo.id}
                phx-value-label={nodo.label}
                class="text-red-600 hover:text-red-800 text-xs font-semibold"
              >
                Eliminar
              </button>
            </div>
          </td>
        </tr>
      <% end %>
    <% end %>
    """
  end
end
