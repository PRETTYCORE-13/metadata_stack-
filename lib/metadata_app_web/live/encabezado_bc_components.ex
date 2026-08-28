defmodule MetadataAppWeb.EncabezadoBcComponents do
  @moduledoc """
  Panel "Encabezado" (etiqueta/navegación/ícono/visible) — extraído de
  BcMotorLive (2026-08-26) para que cualquier otra pantalla de
  configuración de un BC lo reuse tal cual, mismo criterio que
  `MetadataAppWeb.FiltrosDefaultComponents`. Funciona para CUALQUIER
  Header (catálogo normal o Consulta Ecto) — solo toca los 4 campos
  genéricos que ya comparten los dos (`schema_context_label/nav/icono`,
  `schema_visible`), nada específico de un tipo.

  El LiveView que lo use tiene que:

    - Assignar `:header_form` (`form_desde_header/1`), `:iconos_sugeridos`
      (`iconos_sugeridos/0`) y `:carpetas`
      (`MetaSchemaContext.listar_carpetas_existentes/0`).
    - Implementar los 3 `handle_event` que el HEEx dispara (nombres fijos,
      no configurables — hardcodeados en el template de abajo):
      "validar_header" (`phx-change`, valida en vivo mientras se tipea,
      sin guardar), "elegir_icono_header" (click en el selector visual),
      "guardar_header" (`phx-submit`, persiste). Delegar cada uno a
      `validar/2`, `elegir_icono/2`, `guardar/2` de abajo.
  """
  use Phoenix.Component

  alias Phoenix.LiveView.JS
  alias MetadataApp.BusinessProcessBuilder.MetaSchemaContext

  @iconos_sugeridos ~w(
    inventory_2 inventory shopping_cart storefront store sell local_offer
    category label folder folder_open description receipt_long assignment
    checklist rule task list_alt table_chart grid_view apps widgets
    dashboard bar_chart pie_chart insights trending_up payments credit_card
    attach_money account_balance business apartment factory warehouse
    local_shipping directions_car build engineering handyman construction
    group person people badge admin_panel_settings support_agent
    notifications campaign mail chat event schedule calendar_month
    place map public language security lock key qr_code print
    archive star favorite flag settings tune
  )

  def iconos_sugeridos, do: @iconos_sugeridos

  def form_desde_header(header) do
    {carpeta_padre, segmento} = dividir_nav(header.schema_context_nav)

    %{
      "etiqueta" => header.schema_context_label,
      "carpeta_padre" => carpeta_padre,
      "segmento" => segmento,
      "icono" => header.schema_context_icono || "",
      "visible" => header.schema_visible,
      "error" => nil
    }
  end

  # "Navegación" se corrige a raíz de un bug real: dejar la ruta entera como
  # texto libre llevó a que alguien tipeara "/alyconfig/canales" a mano
  # editando OTRO catálogo, pisando sin darse cuenta la ruta de uno que
  # recién se había creado ahí — construir_arbol/1 solo puede mostrar un
  # nodo por ruta, así que el segundo en cargarse "hacía desaparecer" al
  # primero. Separar en carpeta (select, solo rutas de carpeta que ya
  # existen) + segmento propio (texto, pero validado contra colisión antes
  # de guardar) hace ese error estructuralmente imposible en la carpeta, y
  # detectable antes de guardar en el segmento.
  defp dividir_nav(nav) do
    case nav |> String.trim_leading("/") |> String.split("/", trim: true) do
      [] -> {"", ""}
      [unico] -> {"", unico}
      varios -> {varios |> Enum.slice(0..-2//1) |> Enum.join("/"), List.last(varios)}
    end
  end

  defp componer_nav(carpeta_padre, segmento) do
    cond do
      segmento == "" -> ""
      carpeta_padre in [nil, ""] -> "/" <> segmento
      true -> "/" <> carpeta_padre <> "/" <> segmento
    end
  end

  # Permisivo a propósito (no fuerza minúsculas): rutas ya existentes como
  # "/catalogos/Clientes" usan mayúsculas y forzar el case acá las cambiaría
  # solo por tocar este formulario, rompiendo cualquier link/bookmark viejo
  # que dependa del case exacto. Lo que sí se quita son espacios y "/" —
  # que es justo lo que permitía meter una ruta de varios niveles en lo que
  # se pensaba como "solo el segmento final".
  defp sanitizar_segmento(valor) do
    (valor || "")
    |> String.trim()
    |> String.replace(~r/[^A-Za-z0-9\-_]/, "")
    |> String.slice(0, 50)
  end

  defp normalizar_icono(valor) do
    (valor || "")
    |> String.trim()
    |> String.downcase()
    |> quitar_acentos()
    |> String.replace(~r/[^a-z0-9]+/, "_")
    |> String.trim("_")
    |> String.slice(0, 50)
  end

  defp quitar_acentos(valor) do
    valor
    |> String.normalize(:nfd)
    |> String.replace(~r/\p{Mn}/u, "")
  end

  defp nil_si_vacio(""), do: nil
  defp nil_si_vacio(valor), do: valor

  defp colisiona_con_otro?(nav, header_id) do
    case MetaSchemaContext.obtener_header_por_nav(nav) do
      nil -> false
      %{id: ^header_id} -> false
      _otro -> true
    end
  end

  @doc "Delegado de `handle_event(\"validar_header\", %{\"header\" => params}, socket)` — valida en vivo, sin guardar."
  def validar(params, header_id) do
    carpeta_padre = params["carpeta_padre"] || ""
    segmento = sanitizar_segmento(params["segmento"])
    nav = componer_nav(carpeta_padre, segmento)

    error =
      if segmento != "" and colisiona_con_otro?(nav, header_id) do
        "Esa ruta ya la usa otro catálogo o carpeta — elegí otra."
      end

    %{
      "etiqueta" => params["etiqueta"],
      "carpeta_padre" => carpeta_padre,
      "segmento" => segmento,
      "icono" => normalizar_icono(params["icono"]),
      "visible" => params["visible"] == "true",
      "error" => error
    }
  end

  @doc "Delegado de `handle_event(\"elegir_icono_header\", %{\"icono\" => icono}, socket)`."
  def elegir_icono(header_form, icono), do: Map.put(header_form, "icono", icono)

  @doc """
  Delegado de `handle_event("guardar_header", %{"header" => params}, socket)`.
  Devuelve `{:ok, header_actualizado}` o `{:error, header_form_con_error}`
  (mismo `header_form` recibido, con `"error"` puesto) para que el
  caller solo tenga que hacer `assign(:header, ...)`/`assign(:header_form, ...)`
  en el primer caso, `assign(:header_form, ...)` en el segundo.
  """
  def guardar(params, header) do
    etiqueta = String.trim(params["etiqueta"] || "")
    carpeta_padre = params["carpeta_padre"] || ""
    segmento = sanitizar_segmento(params["segmento"])
    nav = componer_nav(carpeta_padre, segmento)

    cond do
      etiqueta == "" ->
        {:error, Map.put(params, "error", "La etiqueta no puede quedar vacía.")}

      segmento == "" ->
        {:error, Map.put(params, "error", "La navegación no puede quedar vacía.")}

      colisiona_con_otro?(nav, header.id) ->
        {:error, Map.put(params, "error", "Esa ruta ya la usa otro catálogo o carpeta — elegí otra.")}

      true ->
        attrs = %{
          "schema_context_label" => etiqueta,
          "schema_context_nav" => nav,
          "schema_context_icono" => nil_si_vacio(normalizar_icono(params["icono"])),
          "schema_visible" => params["visible"] == "true"
        }

        case MetaSchemaContext.actualizar_header(header, attrs) do
          {:ok, header} -> {:ok, header}
          {:error, changeset} -> {:error, Map.put(params, "error", MetadataApp.MetaErrores.resumen(changeset))}
        end
    end
  end

  attr :header_form, :map, required: true
  attr :iconos_sugeridos, :list, required: true
  attr :carpetas, :list, required: true

  def panel_encabezado(assigns) do
    assigns = assign(assigns, :nav_preview, componer_nav(assigns.header_form["carpeta_padre"], assigns.header_form["segmento"]))

    ~H"""
    <div class="border border-gray-200 rounded-lg">
      <div class="px-1.5 ml-2 -mb-2 relative">
        <span class="bg-white px-1.5 font-bold uppercase tracking-wide text-[11px] text-gray-500">Encabezado</span>
      </div>
      <div class="p-3 pt-4">
        <%= if @header_form["error"] do %>
          <div class="bg-red-50 text-red-700 rounded-lg px-2 py-1.5 mb-2">{@header_form["error"]}</div>
        <% end %>

        <form phx-change="validar_header" phx-submit="guardar_header" class="grid grid-cols-[100px_1fr] gap-y-2 gap-x-2 items-center">
          <label class="font-medium text-gray-900">Etiqueta:</label>
          <input type="text" name="header[etiqueta]" value={@header_form["etiqueta"]} required maxlength="100"
            class="border border-gray-300 rounded-lg text-gray-900 px-2 py-1 focus:outline-none focus:ring-2 focus:ring-purple-500/40 focus:border-purple-500" />

          <label class="font-medium text-gray-900">Navegación:</label>
          <div>
            <div class="flex items-center gap-1">
              <select name="header[carpeta_padre]"
                title="Solo carpetas que ya existen en el menú — así no se puede tipear una ruta con errores ni pisar la de otro catálogo."
                class="border border-gray-300 rounded-lg text-gray-900 px-2 py-1 focus:outline-none focus:ring-2 focus:ring-purple-500/40 focus:border-purple-500">
                <option value="" selected={@header_form["carpeta_padre"] in [nil, ""]}>— Sin carpeta (raíz) —</option>
                <%= for carpeta <- @carpetas do %>
                  <option value={carpeta.ruta} selected={@header_form["carpeta_padre"] == carpeta.ruta}>{carpeta.etiqueta}</option>
                <% end %>
              </select>
              <span class="text-gray-400">/</span>
              <input type="text" name="header[segmento]" value={@header_form["segmento"]} required maxlength="50"
                title="Solo el segmento final de este catálogo — sin espacios ni '/'."
                class="border border-gray-300 rounded-lg text-gray-900 px-2 py-1 flex-1 font-mono focus:outline-none focus:ring-2 focus:ring-purple-500/40 focus:border-purple-500" />
            </div>
            <div class="mt-1 bg-purple-50 border border-purple-200 text-purple-700 rounded-lg px-1.5 py-0.5 inline-flex items-center gap-1">
              <span class="text-purple-400">Vista previa:</span>
              <span class="font-mono">{@nav_preview}</span>
            </div>
          </div>

          <label class="font-medium text-gray-900">Ícono:</label>
          <div>
            <input type="hidden" name="header[icono]" value={@header_form["icono"]} />
            <button type="button" phx-click={JS.toggle(to: "#selector-iconos-header")}
              class="w-6 h-6 flex items-center justify-center border border-gray-300 rounded-lg bg-gray-50 hover:bg-gray-100 text-gray-700 transition-colors" title="Elegir ícono">
              <%= if @header_form["icono"] not in [nil, ""] do %>
                <span class="material-symbols-outlined" style="font-size: 16px">{@header_form["icono"]}</span>
              <% else %>
                <span class="material-symbols-outlined text-gray-400" style="font-size: 16px">apps</span>
              <% end %>
            </button>

            <div id="selector-iconos-header" class="hidden mt-1 border border-gray-200 rounded-lg bg-white shadow-lg p-1.5 max-w-md">
              <div class="grid grid-cols-10 gap-0.5 max-h-40 overflow-y-auto">
                <%= for icono <- @iconos_sugeridos do %>
                  <button type="button" title={icono}
                    phx-click={JS.push("elegir_icono_header", value: %{icono: icono}) |> JS.hide(to: "#selector-iconos-header")}
                    class={[
                      "w-6 h-6 flex items-center justify-center rounded-lg text-gray-700 hover:bg-purple-50 hover:text-purple-700 transition-colors",
                      @header_form["icono"] == icono && "bg-purple-100 text-purple-700"
                    ]}>
                    <span class="material-symbols-outlined" style="font-size: 16px">{icono}</span>
                  </button>
                <% end %>
              </div>
            </div>
          </div>

          <div></div>
          <label class="flex items-center gap-1.5 font-medium text-gray-900 cursor-pointer select-none">
            <input type="hidden" name="header[visible]" value="false" />
            <input type="checkbox" name="header[visible]" value="true" checked={@header_form["visible"] == true} class="accent-purple-600" />
            Es visible
          </label>

          <div></div>
          <div>
            <button type="submit" class="px-3 py-1.5 rounded-lg bg-purple-600 text-white font-semibold hover:bg-purple-700 transition-colors">
              Guardar encabezado
            </button>
          </div>
        </form>
      </div>
    </div>
    """
  end
end
