defmodule MetadataAppWeb.Sysadmin.TepacheLive do
  @moduledoc """
  "Tepache Exp/Imp" — pantalla mínima para armar/importar un tepache
  (bundle de previsualización entre desarrolladores, ver docs/roadmap.md
  #14) sin pasar por `mix`. Comparte toda la lógica con
  `mix motor.tepache`/`mix motor.tepache.importar` vía
  `MetadataApp.MetaTepache` — acá solo la interfaz.

  Dev-only, igual que Business Process Builder: no tiene sentido en
  producción (no hay `gh`/compilador ahí, y el punto es compartir un BC
  entre Postgres LOCALES de cada desarrollador) — gateada por
  `bpb_habilitado` en el router, igual que BC List.
  """

  use MetadataAppWeb, :live_view_admin

  on_mount {MetadataAppWeb.UsuarioAuth, :mount_current_scope}
  on_mount {MetadataAppWeb.Hooks.Autorizacion, {"sysadmin_bc", "leer"}}

  alias MetadataApp.BusinessProcessBuilder.MetaSchemaContext
  alias MetadataApp.MetaTepache
  alias MetadataAppWeb.AdminNav

  @menu [
    %{tipo: :pagina, id: "bc_list", label: "BC List", nav: "/sysadmin/bc-list"},
    %{tipo: :pagina, id: "buscar_trn", label: "Buscar TRN", nav: "/sysadmin/buscar-trn"},
    %{tipo: :pagina, id: "tepache", label: "Tepache Exp/Imp", nav: "/sysadmin/tepache"},
    %{tipo: :pagina, id: "roles", label: "Roles y Usuarios", nav: "/sysadmin/roles"},
    %{tipo: :pagina, id: "usuarios_empresa", label: "Usuarios", nav: "/sysadmin/usuarios"},
    %{tipo: :pagina, id: "credenciales", label: "Credenciales", nav: "/sysadmin/credenciales"},
    %{tipo: :pagina, id: "acciones_externas", label: "Acciones externas", nav: "/sysadmin/acciones-externas"}
  ]

  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:current_page, "tepache")
     |> assign(:menu_items, @menu)
     |> assign(:sidebar_open, false)
     |> assign(:show_programacion_children, false)
     |> assign(:show_clientes_children, false)
     |> assign(:show_prettycore_children, false)
     |> assign(:busqueda_catalogo, "")
     |> assign(:resultados_catalogo, [])
     |> assign(:seleccionados, [])
     |> assign(:resultado_export, nil)
     |> assign(:tag_importar, "")
     |> assign(:resultado_import, nil)
     |> assign(:pendiente_confirmacion, nil)}
  end

  def handle_event("change_page", %{"id" => id}, socket) do
    AdminNav.handle_nav(id, socket, "tepache")
  end

  def handle_event("buscar_catalogo", %{"value" => texto}, socket) do
    resultados = MetaSchemaContext.buscar_catalogos_raiz(texto)
    {:noreply, socket |> assign(:busqueda_catalogo, texto) |> assign(:resultados_catalogo, resultados)}
  end

  def handle_event("agregar_seleccionado", %{"recurso" => recurso}, socket) do
    {:noreply, assign(socket, :seleccionados, Enum.uniq(socket.assigns.seleccionados ++ [recurso]))}
  end

  def handle_event("quitar_seleccionado", %{"recurso" => recurso}, socket) do
    {:noreply, assign(socket, :seleccionados, List.delete(socket.assigns.seleccionados, recurso))}
  end

  def handle_event("exportar_tepache", params, socket) do
    descripcion = Map.get(params, "descripcion", "")
    resultado = MetaTepache.exportar(socket.assigns.seleccionados, descripcion)
    {:noreply, assign(socket, :resultado_export, resultado)}
  end

  # Paso 1: preparar_import/1 nunca toca nada (ni migra ni extrae) — solo
  # baja el bundle y detecta si haría falta confirmar una eliminación de
  # campos. Si no hace falta, se aplica de una — si hace falta, se le
  # pregunta al usuario antes de tocar cualquier dato.
  def handle_event("importar_tepache", %{"tag" => tag}, socket) do
    tag = String.trim(tag)

    if tag == "" do
      {:noreply,
       socket
       |> assign(:tag_importar, tag)
       |> assign(:resultado_import, {:error, "Ingresá un tag (ej. TEPACHE-000002)."})}
    else
      importar(socket, tag)
    end
  end

  def handle_event("confirmar_import", _params, socket) do
    aplicar_import(socket, socket.assigns.tag_importar, socket.assigns.pendiente_confirmacion)
  end

  def handle_event("cancelar_import", _params, socket) do
    {:noreply, assign(socket, :pendiente_confirmacion, nil)}
  end

  defp importar(socket, tag) do
    case MetaTepache.preparar_import(tag) do
      {:error, mensaje} ->
        {:noreply, socket |> assign(:tag_importar, tag) |> assign(:resultado_import, {:error, mensaje})}

      {:ok, %{campos_removidos: campos_removidos} = info} ->
        if campos_removidos == %{} do
          aplicar_import(socket, tag, info)
        else
          {:noreply,
           socket
           |> assign(:tag_importar, tag)
           |> assign(:resultado_import, nil)
           |> assign(:pendiente_confirmacion, info)}
        end
    end
  end

  defp aplicar_import(socket, tag, info) do
    resultado = MetaTepache.aplicar_import(info)

    {:noreply,
     socket
     |> assign(:tag_importar, tag)
     |> assign(:pendiente_confirmacion, nil)
     |> assign(:resultado_import, resultado)}
  end

  def render(assigns) do
    ~H"""
    <div class="max-w-4xl mx-auto p-8 space-y-8">
      <div class="flex items-center gap-2">
        <.link navigate={~p"/"} title="Volver al inicio"
          class="w-7 h-7 flex items-center justify-center rounded-lg text-gray-500 hover:bg-gray-100 hover:text-gray-700 transition-colors shrink-0">
          <span class="material-symbols-outlined" style="font-size: 18px">arrow_back</span>
        </.link>
        <h1 class="text-2xl font-bold">Tepache Exp/Imp</h1>
      </div>

      <!-- ── Exportar ── -->
      <div class="rounded-xl border border-gray-200 p-5">
        <h2 class="text-lg font-bold text-gray-900 mb-1">Exportar</h2>
        <p class="text-sm text-gray-500 mb-4">
          Armá un tepache con uno o más catálogos para que otro desarrollador lo importe en su Postgres local — sin publicar nada a producción.
        </p>

        <input
          type="text"
          value={@busqueda_catalogo}
          phx-keyup="buscar_catalogo"
          phx-debounce="200"
          placeholder="Buscar catálogo por nombre o etiqueta..."
          class="w-full border border-gray-300 rounded-lg px-4 py-2 text-sm text-gray-900 mb-2"
        />

        <ul :if={@resultados_catalogo != []} class="border border-gray-200 rounded-lg divide-y divide-gray-100 mb-4">
          <li :for={c <- @resultados_catalogo} class="flex items-center justify-between px-3 py-2">
            <span class="text-sm text-gray-800">{c.label} <span class="text-xs text-gray-400 font-mono">({c.recurso})</span></span>
            <button
              type="button"
              phx-click="agregar_seleccionado"
              phx-value-recurso={c.recurso}
              class="text-xs text-purple-700 font-semibold hover:underline"
            >
              Agregar
            </button>
          </li>
        </ul>

        <div :if={@seleccionados != []} class="flex flex-wrap gap-2 mb-4">
          <span :for={recurso <- @seleccionados} class="inline-flex items-center gap-1.5 px-2.5 py-1 rounded-full text-xs font-semibold bg-purple-50 text-purple-700 border border-purple-100">
            {recurso}
            <button type="button" phx-click="quitar_seleccionado" phx-value-recurso={recurso} class="text-purple-400 hover:text-purple-700">
              ×
            </button>
          </span>
        </div>

        <form phx-submit="exportar_tepache">
          <label class="text-xs font-semibold text-gray-500">Motivo / impacto / notas (opcional)</label>
          <textarea
            name="descripcion"
            rows="2"
            placeholder="Ej.: agrego validación de crédito antes de aprobar, revisen el detalle de líneas..."
            class="w-full border border-gray-300 rounded-lg px-3 py-2 text-sm text-gray-900 mb-3"
          ></textarea>

          <button
            type="submit"
            phx-disable-with="Armando y subiendo..."
            disabled={@seleccionados == []}
            class="bg-purple-600 hover:bg-purple-700 disabled:opacity-40 disabled:cursor-not-allowed text-white font-bold px-4 py-2 rounded text-sm"
          >
            Exportar tepache ({length(@seleccionados)})
          </button>
        </form>

        <.resultado_export resultado={@resultado_export} />
      </div>

      <!-- ── Importar ── -->
      <div class="rounded-xl border border-gray-200 p-5">
        <h2 class="text-lg font-bold text-gray-900 mb-1">Importar</h2>
        <p class="text-sm text-gray-500 mb-4">
          Pegá el tag de un tepache que te compartió otro desarrollador (ej. <span class="font-mono">TEPACHE-000001</span>) para traerlo a tu Postgres local.
        </p>

        <form phx-submit="importar_tepache" class="flex items-center gap-2">
          <input
            type="text"
            name="tag"
            value={@tag_importar}
            placeholder="TEPACHE-000001"
            class="flex-1 border border-gray-300 rounded-lg px-4 py-2 text-sm text-gray-900 font-mono"
          />
          <button
            type="submit"
            phx-disable-with="Revisando..."
            class="bg-purple-600 hover:bg-purple-700 text-white font-bold px-4 py-2 rounded text-sm whitespace-nowrap"
          >
            Importar
          </button>
        </form>

        <.confirmacion_remocion pendiente={@pendiente_confirmacion} />
        <.resultado_import resultado={@resultado_import} />
      </div>
    </div>
    """
  end

  attr :pendiente, :any, required: true

  defp confirmacion_remocion(%{pendiente: nil} = assigns), do: ~H""

  defp confirmacion_remocion(assigns) do
    ~H"""
    <div class="mt-4 rounded-lg border border-amber-300 bg-amber-50 text-amber-900 text-sm px-3 py-3 space-y-2">
      <p class="font-bold">Este tepache no trae campos que tú sí tienes localmente:</p>
      <ul class="space-y-0.5">
        <li :for={{catalogo, campos} <- @pendiente.campos_removidos}>
          <span class="font-mono">{catalogo}</span>: {Enum.join(campos, ", ")}
        </li>
      </ul>
      <p>Si se quitaron a propósito en el origen, se pierden los datos de esas columnas al confirmar.</p>
      <div class="flex gap-2 pt-1">
        <button
          type="button"
          phx-click="cancelar_import"
          class="px-3 py-1.5 rounded border border-gray-300 bg-white text-gray-700 text-xs font-semibold hover:bg-gray-50"
        >
          Cancelar
        </button>
        <button
          type="button"
          phx-click="confirmar_import"
          phx-disable-with="Aplicando..."
          class="px-3 py-1.5 rounded bg-amber-600 text-white text-xs font-semibold hover:bg-amber-700"
        >
          Confirmar y eliminar esos campos
        </button>
      </div>
    </div>
    """
  end

  attr :resultado, :any, required: true

  defp resultado_export(%{resultado: nil} = assigns), do: ~H""

  defp resultado_export(%{resultado: {:error, mensaje}} = assigns) do
    assigns = assign(assigns, :mensaje, mensaje)

    ~H"""
    <div class="mt-4 rounded-lg border border-red-200 bg-red-50 text-red-700 text-sm px-3 py-2">
      {@mensaje}
    </div>
    """
  end

  defp resultado_export(%{resultado: {:ok, _}} = assigns) do
    %{tag: tag, catalogos: catalogos, automaticos: automaticos, problemas: problemas} = elem(assigns.resultado, 1)

    assigns =
      assigns
      |> assign(:tag, tag)
      |> assign(:catalogos, catalogos)
      |> assign(:automaticos, automaticos)
      |> assign(:problemas, problemas)

    ~H"""
    <div class="mt-4 rounded-lg border border-green-200 bg-green-50 text-green-800 text-sm px-3 py-2 space-y-1">
      <p class="font-bold">
        Listo — <span class="font-mono">{@tag}</span>
      </p>
      <p>Paquete completo: <span class="font-mono">{Enum.join(@catalogos, ", ")}</span></p>
      <p :if={@automaticos != []}>Incluidos automáticamente: <span class="font-mono">{Enum.join(@automaticos, ", ")}</span></p>
      <p :if={@problemas != []} class="text-amber-800">
        <span :for={p <- @problemas}>[{p.severidad}] {p.mensaje}<br /></span>
      </p>
      <p class="text-xs text-green-700">
        Compartí el tag <span class="font-mono">{@tag}</span> para que alguien lo importe.
      </p>
    </div>
    """
  end

  attr :resultado, :any, required: true

  defp resultado_import(%{resultado: nil} = assigns), do: ~H""

  defp resultado_import(%{resultado: {:error, mensaje}} = assigns) do
    assigns = assign(assigns, :mensaje, mensaje)

    ~H"""
    <div class="mt-4 rounded-lg border border-red-200 bg-red-50 text-red-700 text-sm px-3 py-2">
      {@mensaje}
    </div>
    """
  end

  defp resultado_import(%{resultado: {:ok, _}} = assigns) do
    %{catalogos: catalogos, mensajes: mensajes} = elem(assigns.resultado, 1)
    assigns = assigns |> assign(:catalogos, catalogos) |> assign(:mensajes, mensajes)

    ~H"""
    <div class="mt-4 rounded-lg border border-green-200 bg-green-50 text-green-800 text-sm px-3 py-2 space-y-1">
      <p class="font-bold">Listo — <span class="font-mono">{Enum.join(@catalogos, ", ")}</span> ya está en tu Postgres local.</p>
      <p :for={m <- @mensajes} class="text-xs text-green-700">{m}</p>
      <p class="text-xs text-green-700">
        Para probarlo con un rol puntual, concedeselo desde Permission Sets.
      </p>
    </div>
    """
  end
end
