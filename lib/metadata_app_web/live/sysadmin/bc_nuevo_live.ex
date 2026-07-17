defmodule MetadataAppWeb.Sysadmin.BcNuevoLive do
  # Ventana emergente, sin el layout admin (sidebar/topbar) — solo el
  # formulario, así se ve limpio dentro de la ventana chica.
  use MetadataAppWeb, :live_view

  alias MetadataApp.BusinessProcessBuilder.MetaSchemaContext
  alias MetadataApp.BusinessProcessBuilder.CatalogoGenerador
  alias Phoenix.LiveView.JS

  @topic "bc_contextos"

  @tipos ~w(string integer decimal boolean date enum referencia)

  # Subconjunto curado de Material Symbols para el selector visual — no son
  # los únicos válidos (el campo de texto sigue aceptando cualquier nombre
  # de fonts.google.com/icons), solo los más comunes para catálogos/menús
  # de negocio, para no tener que ir a buscar cada vez.
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

  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:mensaje, nil)
     |> assign(:carpetas, MetaSchemaContext.listar_carpetas_existentes())
     |> nuevo_formulario()}
  end

  # Sin esto el servidor nunca se entera de lo tecleado hasta el submit —
  # cualquier vuelta al servidor antes de eso (agregar/quitar fila) repinta
  # el formulario con los valores viejos y borra lo escrito.
  # "componentes" no llega en los params cuando el tipo es "carpeta" — ese
  # fieldset ni se pinta en el HTML, así que no hay nada que mandar. Se
  # trata como opcional en vez de exigirlo en el pattern match.
  def handle_event("validar", %{"contexto" => contexto} = params, socket) do
    contexto =
      contexto
      |> Map.put("visible", contexto["visible"] == "true")
      |> Map.put("nombre_p2", normalizar_identificador(contexto["nombre_p2"]))
      |> Map.put("nombre_p3", normalizar_identificador(contexto["nombre_p3"]))
      |> Map.put("nav_final", normalizar_slug(contexto["nav_final"]))
      |> Map.put("icono", normalizar_icono(contexto["icono"]))

    socket = assign(socket, :contexto, contexto)

    socket =
      case params["componentes"] do
        nil ->
          socket

        componentes_map ->
          componentes =
            componentes_map
            |> Enum.sort_by(fn {idx, _} -> String.to_integer(idx) end)
            |> Enum.map(fn {_idx, c} -> Map.put(c, "visible", c["visible"] == "true") end)

          assign(socket, :componentes, componentes)
      end

    {:noreply, socket}
  end

  def handle_event("agregar_componente", _params, socket) do
    componentes = socket.assigns.componentes ++ [componente_vacio(length(socket.assigns.componentes) + 1)]
    {:noreply, assign(socket, :componentes, componentes)}
  end

  def handle_event("quitar_componente", %{"idx" => idx}, socket) do
    idx = String.to_integer(idx)
    {:noreply, assign(socket, :componentes, List.delete_at(socket.assigns.componentes, idx))}
  end

  def handle_event("elegir_icono", %{"icono" => icono}, socket) do
    {:noreply, update(socket, :contexto, &Map.put(&1, "icono", icono))}
  end

  def handle_event("cancelar", _params, socket) do
    {:noreply, socket |> nuevo_formulario() |> assign(:mensaje, nil)}
  end

  # Mismo motivo que en "validar": si es carpeta, el form nunca manda
  # "componentes" (el fieldset no existe en el DOM).
  def handle_event("guardar", %{"contexto" => contexto} = params, socket) do
    contexto = Map.put(contexto, "nav", componer_nav(contexto["carpeta_padre"], contexto["nav_final"]))
    es_carpeta? = contexto["tipo_registro"] == "carpeta"

    # Si es carpeta, "Nombre de sistema" ni se muestra en el form — se
    # deriva solo de la Navegación (única info disponible que la identifica).
    # Si es archivo, sigue viniendo de las 3 cajitas de siempre.
    contexto =
      if es_carpeta? do
        Map.put(contexto, "nombre", nombre_desde_nav(contexto["nav"]))
      else
        Map.put(contexto, "nombre", combinar_nombre_sistema(contexto["nombre_p2"], contexto["nombre_p3"]))
      end

    componentes =
      params
      |> Map.get("componentes", %{})
      |> Enum.sort_by(fn {idx, _} -> String.to_integer(idx) end)
      |> Enum.map(fn {_idx, c} -> c end)

    case validar_formulario(contexto, componentes, es_carpeta?) do
      :ok ->
        header_attrs = %{
          "schema_context_name" => contexto["nombre"],
          "schema_context_label" => contexto["etiqueta"],
          "schema_context_nav" => contexto["nav"],
          "schema_visible" => contexto["visible"] == "true",
          "schema_context_type" => if(es_carpeta?, do: 2, else: 1),
          "schema_context_icono" => nil_si_vacio(normalizar_icono(contexto["icono"])),
          "detalles" => if(es_carpeta?, do: [], else: Enum.map(componentes, &detalle_attrs/1))
        }

        case MetaSchemaContext.crear_header_con_detalles(header_attrs) do
          {:ok, {header, _detalles}} ->
            texto = guardar_texto_resultado(es_carpeta?, header)

            Phoenix.PubSub.broadcast(MetadataApp.PubSub, @topic, {:bc_creado, header})

            {:noreply,
             socket
             |> nuevo_formulario()
             |> assign(:mensaje, {:ok, texto})
             |> push_event("cerrar_ventana", %{})}

          {:error, changeset} ->
            {:noreply, assign(socket, :mensaje, {:error, resumen_errores(changeset)})}
        end

      {:error, motivo} ->
        {:noreply, assign(socket, :mensaje, {:error, motivo})}
    end
  end

  # Una carpeta no tiene tabla que generar — solo el nodo de menú.
  defp guardar_texto_resultado(true, header),
    do: "Carpeta '#{header.schema_context_label}' guardada."

  defp guardar_texto_resultado(false, header) do
    case CatalogoGenerador.generar(header.schema_context_name) do
      {:ok, %{ya_existia: true}} -> "Contexto '#{header.schema_context_label}' guardado (el catálogo ya existía)."
      {:ok, _} -> "Contexto '#{header.schema_context_label}' guardado y catálogo generado."
      {:error, motivo} -> "Contexto guardado, pero no se pudo generar el catálogo: #{motivo}"
    end
  end

  # No basta con las restricciones del navegador (pattern/maxlength) — un
  # cliente HTTP directo a este LiveView se las salta. schema_context_name y
  # schema_context_field terminan siendo identificadores reales de Postgres
  # (nombre de tabla / nombre de columna), así que se validan aquí también.
  @identificador ~r/^[a-z][a-z0-9_]{0,49}$/
  @nav ~r/^\/[a-z0-9\-\/]{0,49}$/

  defp validar_formulario(contexto, componentes, es_carpeta?) do
    with :ok <- validar_regex(contexto["nombre"], @identificador, "Nombre de sistema"),
         :ok <- validar_regex(contexto["nav"], @nav, "Navegación"),
         :ok <- validar_completado(contexto["etiqueta"], "Catálogo de", "Etiqueta") do
      # Una carpeta no tiene Componentes que validar — es solo un nodo de menú.
      if es_carpeta? do
        :ok
      else
        componentes
        |> Enum.with_index(1)
        |> Enum.reduce_while(:ok, fn {c, i}, :ok ->
          case validar_regex(c["nombre"], @identificador, "Nombre del componente ##{i}") do
            :ok -> {:cont, :ok}
            error -> {:halt, error}
          end
        end)
      end
    end
  end

  defp validar_regex(valor, regex, etiqueta) do
    if valor && Regex.match?(regex, valor) do
      :ok
    else
      {:error, "#{etiqueta} inválido: '#{valor}'. Debe cumplir el formato requerido (ver la ayuda del campo)."}
    end
  end

  # No basta con dejar el valor por default (ej. solo "pty_" o "/catalogos/"
  # sin completar) — tiene que haber algo real después del prefijo.
  defp validar_completado(valor, prefijo, etiqueta) do
    resto =
      (valor || "")
      |> String.trim()
      |> String.trim_leading(prefijo)
      |> String.trim()

    if resto == "" do
      {:error, "#{etiqueta} no puede quedarse solo con el valor por default — completa el resto."}
    else
      :ok
    end
  end

  # Combina las 3 cajitas del campo "Nombre de sistema": pty_ (fijo) +
  # segunda parte + tercera parte, cada una limpia por separado. Si falta
  # cualquiera de las dos partes editables, devuelve "" — eso hace que
  # validar_regex/3 lo rechace solo, sin necesitar un chequeo aparte.
  defp combinar_nombre_sistema(parte2, parte3) do
    p2 = normalizar_identificador(parte2)
    p3 = normalizar_identificador(parte3)

    if p2 == "" or p3 == "" do
      ""
    else
      String.slice("pty_#{p2}_#{p3}", 0, 50)
    end
  end

  # Para carpetas, el "Nombre de sistema" no se pide en el form — se arma
  # solo a partir de los segmentos de la Navegación, que es la única
  # información propia de una carpeta.
  defp nombre_desde_nav(nav) do
    sufijo =
      nav
      |> String.trim_leading("/")
      |> String.split("/", trim: true)
      |> Enum.map(&normalizar_identificador/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("_")

    if sufijo == "", do: "", else: String.slice("pty_carpeta_#{sufijo}", 0, 50)
  end

  defp normalizar_identificador(valor) do
    (valor || "")
    |> String.downcase()
    |> quitar_acentos()
    |> String.replace(~r/[^a-z0-9_]/, "")
    |> String.replace(~r/^[^a-z]+/, "")
    |> String.slice(0, 50)
  end

  defp quitar_acentos(valor) do
    valor
    |> String.normalize(:nfd)
    |> String.replace(~r/\p{Mn}/u, "")
  end

  # Nombre del ícono de Material Symbols (fonts.google.com/icons) — la UI de
  # Google los muestra en "Title Case" (ej. "Inventory 2") pero el nombre
  # real del glyph es snake_case ("inventory_2"), así que se normaliza para
  # no depender de que el usuario lo pegue ya en el formato exacto. Devuelve
  # "" (no nil) para que el campo se redibuje igual que nombre_p2/nav_final;
  # el guardado convierte "" a nil (sin ícono = cae al genérico de siempre).
  defp normalizar_icono(valor) do
    (valor || "")
    |> String.trim()
    |> String.downcase()
    |> quitar_acentos()
    |> String.replace(~r/[^a-z0-9]+/, "_")
    |> String.trim("_")
    |> String.slice(0, 50)
  end

  defp nil_si_vacio(""), do: nil
  defp nil_si_vacio(valor), do: valor

  # Solo el segmento final del nav (lo que escribe el usuario en "Nombre en
  # el menú") — minúsculas, sin acentos/espacios, guiones sí permitidos
  # (a diferencia de normalizar_identificador/1, que es para nombres pty_*).
  defp normalizar_slug(valor) do
    (valor || "")
    |> String.downcase()
    |> quitar_acentos()
    |> String.replace(~r/[^a-z0-9\-]/, "")
    |> String.slice(0, 50)
  end

  # Compone el nav final: carpeta_padre (elegida del selector, puede venir
  # vacía = raíz) + el segmento propio. Así ya no hay que escribir la ruta
  # completa a mano ni arriesgarse a un typo que no calce con ninguna
  # carpeta existente.
  defp componer_nav(carpeta_padre, nav_final) do
    segmento = normalizar_slug(nav_final)

    cond do
      segmento == "" -> ""
      carpeta_padre in [nil, ""] -> "/" <> segmento
      true -> String.slice("/" <> carpeta_padre <> "/" <> segmento, 0, 50)
    end
  end

  defp nuevo_formulario(socket) do
    socket
    |> assign(:contexto, %{
      "tipo_registro" => "archivo",
      "nombre_p2" => "catalogos",
      "nombre_p3" => "",
      "etiqueta" => "Catálogo de ",
      "carpeta_padre" => "",
      "nav_final" => "",
      "icono" => "",
      "visible" => true
    })
    |> assign(:componentes, [componente_vacio(1)])
  end

  defp componente_vacio(orden) do
    %{
      "nombre" => "",
      "etiqueta" => "",
      "tipo" => "string",
      "longitud" => "",
      "precision" => "",
      "escala" => "",
      "orden" => to_string(orden),
      "visible" => true
    }
  end

  defp detalle_attrs(c) do
    propiedades =
      %{
        "etiqueta" => c["etiqueta"],
        "tipo" => c["tipo"],
        "orden" => String.to_integer(c["orden"] || "1"),
        "visible" => c["visible"] == "true",
        "editable" => true
      }
      |> agregar_opciones_tipo(c)

    %{"schema_context_field" => c["nombre"], "schema_context_properties" => propiedades}
  end

  defp agregar_opciones_tipo(propiedades, %{"tipo" => "string"} = c),
    do: maybe_put_int(propiedades, "longitud", c["longitud"])

  defp agregar_opciones_tipo(propiedades, %{"tipo" => "decimal"} = c) do
    propiedades
    |> maybe_put_int("precision", c["precision"])
    |> maybe_put_int("escala", c["escala"])
  end

  defp agregar_opciones_tipo(propiedades, _c), do: propiedades

  defp maybe_put_int(map, _key, val) when val in ["", nil], do: map
  defp maybe_put_int(map, key, val), do: Map.put(map, key, String.to_integer(val))

  defp resumen_errores(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {k, v}, acc -> String.replace(acc, "%{#{k}}", to_string(v)) end)
    end)
    |> inspect()
  end

  def render(assigns) do
    nombre_sistema = combinar_nombre_sistema(assigns.contexto["nombre_p2"], assigns.contexto["nombre_p3"])
    nav_preview = componer_nav(assigns.contexto["carpeta_padre"], assigns.contexto["nav_final"])

    assigns =
      assigns
      |> assign(:tipos, @tipos)
      |> assign(:nombre_sistema_preview, nombre_sistema)
      |> assign(:nav_preview, nav_preview)
      |> assign(:iconos_sugeridos, @iconos_sugeridos)

    ~H"""
    <div class="min-h-screen bg-white">
    <div class="max-w-6xl mx-auto">
      <div class="bg-black text-white px-6 py-3 flex justify-end">
        <span class="italic">Business Contexts Admin</span>
      </div>

      <%= if @mensaje do %>
        <div class={[
          "px-6 py-3 text-sm font-medium",
          elem(@mensaje, 0) == :ok && "bg-green-50 text-green-700",
          elem(@mensaje, 0) == :error && "bg-red-50 text-red-700"
        ]}>
          {elem(@mensaje, 1)}
        </div>
      <% end %>

      <form phx-submit="guardar" phx-change="validar" class="p-6 space-y-6">
        <fieldset class="border border-blue-300 rounded">
          <legend class="px-2 ml-2 text-sm font-semibold text-gray-900">Contexto</legend>
          <div class="grid grid-cols-[160px_1fr] gap-y-3 gap-x-3 p-4 items-center">
            <label class="font-medium text-gray-900">Tipo:</label>
            <div class="inline-flex rounded-lg border border-gray-300 overflow-hidden text-sm w-fit">
              <label class={[
                "px-4 py-2 cursor-pointer transition-colors select-none",
                if(@contexto["tipo_registro"] == "carpeta",
                  do: "bg-purple-600 text-white font-semibold",
                  else: "bg-white text-gray-600 hover:bg-gray-50"
                )
              ]}>
                <input type="radio" name="contexto[tipo_registro]" value="carpeta" checked={@contexto["tipo_registro"] == "carpeta"} class="hidden" />
                Árbol de navegación
              </label>
              <label class={[
                "px-4 py-2 cursor-pointer transition-colors select-none border-l border-gray-300",
                if(@contexto["tipo_registro"] != "carpeta",
                  do: "bg-purple-600 text-white font-semibold",
                  else: "bg-white text-gray-600 hover:bg-gray-50"
                )
              ]}>
                <input type="radio" name="contexto[tipo_registro]" value="archivo" checked={@contexto["tipo_registro"] != "carpeta"} class="hidden" />
                Proceso de negocio
              </label>
            </div>

            <%= if @contexto["tipo_registro"] != "carpeta" do %>
              <label class="font-medium text-gray-900">Nombre de sistema:</label>
              <div>
                <div class="flex items-center gap-1.5">
                  <span class="border border-gray-300 rounded bg-gray-100 text-gray-500 px-2 py-1 select-none">pty_</span>
                  <span class="text-gray-400">-</span>
                  <input type="text" name="contexto[nombre_p2]" value={@contexto["nombre_p2"]} required maxlength="30"
                    title="Minúsculas, sin acentos ni espacios."
                    class="border border-gray-300 rounded text-gray-900 px-2 py-1 w-32" placeholder="catalogos" />
                  <span class="text-gray-400">-</span>
                  <input type="text" name="contexto[nombre_p3]" value={@contexto["nombre_p3"]} required maxlength="30"
                    title="Minúsculas, sin acentos ni espacios."
                    class="border border-gray-300 rounded text-gray-900 px-2 py-1 flex-1" placeholder="carros" />
                </div>
                <div class="mt-1.5 bg-blue-600 text-white rounded px-2 py-1.5 text-xs inline-flex items-center gap-1.5">
                  <span class="text-blue-100">Vista previa:</span>
                  <span class="font-mono">{@nombre_sistema_preview}</span>
                </div>
              </div>
            <% end %>

            <label class="font-medium text-gray-900">Etiqueta:</label>
            <input type="text" name="contexto[etiqueta]" value={@contexto["etiqueta"]} required maxlength="100"
              class="border border-gray-300 rounded text-gray-900 px-2 py-1" placeholder="Catálogo de carros" />

            <label class="font-medium text-gray-900">Navegación:</label>
            <div>
              <div class="flex items-center gap-1.5">
                <select name="contexto[carpeta_padre]"
                  title="Elige una carpeta que ya existe para anidar ahí adentro, o deja 'Sin carpeta' para que quede en la raíz del menú."
                  class="border border-gray-300 rounded text-gray-900 px-2 py-1">
                  <option value="" selected={@contexto["carpeta_padre"] in [nil, ""]}>— Sin carpeta (raíz) —</option>
                  <%= for carpeta <- @carpetas do %>
                    <option value={carpeta.ruta} selected={@contexto["carpeta_padre"] == carpeta.ruta}>{carpeta.etiqueta}</option>
                  <% end %>
                </select>
                <span class="text-gray-400">/</span>
                <input type="text" name="contexto[nav_final]" value={@contexto["nav_final"]} required maxlength="50"
                  title="Minúsculas, sin acentos ni espacios. Guiones sí permitidos."
                  class="border border-gray-300 rounded text-gray-900 px-2 py-1 flex-1" placeholder="carros" />
              </div>
              <div class="mt-1.5 bg-blue-600 text-white rounded px-2 py-1.5 text-xs inline-flex items-center gap-1.5">
                <span class="text-blue-100">Vista previa:</span>
                <span class="font-mono">
                  {@nav_preview}<%= if @nombre_sistema_preview != "", do: "/#{@nombre_sistema_preview}" %>
                </span>
              </div>
            </div>

            <label class="font-medium text-gray-900">Ícono:</label>
            <div>
              <input type="hidden" name="contexto[icono]" value={@contexto["icono"]} />
              <button
                type="button"
                phx-click={JS.toggle(to: "#selector-iconos")}
                class="w-9 h-9 flex items-center justify-center border border-gray-300 rounded bg-gray-50 hover:bg-gray-100 text-gray-700"
                title="Elegir ícono"
              >
                <%= if @contexto["icono"] not in [nil, ""] do %>
                  <span class="material-symbols-outlined">{@contexto["icono"]}</span>
                <% else %>
                  <span class="material-symbols-outlined text-gray-400">apps</span>
                <% end %>
              </button>

              <div id="selector-iconos" class="hidden mt-1.5 border border-gray-200 rounded-lg bg-white shadow-sm p-2 max-w-md">
                <div class="grid grid-cols-8 gap-1 max-h-48 overflow-y-auto">
                  <%= for icono <- @iconos_sugeridos do %>
                    <button
                      type="button"
                      title={icono}
                      phx-click={JS.push("elegir_icono", value: %{icono: icono}) |> JS.hide(to: "#selector-iconos")}
                      class={[
                        "w-9 h-9 flex items-center justify-center rounded text-gray-700 hover:bg-purple-50 hover:text-purple-700",
                        @contexto["icono"] == icono && "bg-purple-100 text-purple-700"
                      ]}
                    >
                      <span class="material-symbols-outlined">{icono}</span>
                    </button>
                  <% end %>
                </div>
              </div>

              <p class="mt-1 text-xs text-gray-500">Opcional — se ve en el menú colapsado.</p>
            </div>

            <label class="font-medium text-gray-900">Es visible:</label>
            <div>
              <input type="hidden" name="contexto[visible]" value="false" />
              <input type="checkbox" name="contexto[visible]" value="true" checked={@contexto["visible"] == true} />
            </div>
          </div>
        </fieldset>

        <%= if @contexto["tipo_registro"] != "carpeta" do %>
        <fieldset class="border border-blue-300 rounded">
          <legend class="px-2 ml-2 text-sm font-semibold text-gray-900">Componentes</legend>
          <div class="p-4 overflow-x-auto">
            <table class="min-w-full text-sm">
              <thead class="bg-black text-white">
                <tr>
                  <th class="px-2 py-1 text-left">Nombre</th>
                  <th class="px-2 py-1 text-left">Etiqueta</th>
                  <th class="px-2 py-1 text-left">Tipo</th>
                  <th class="px-2 py-1 text-left">Longitud</th>
                  <th class="px-2 py-1 text-left">precisión</th>
                  <th class="px-2 py-1 text-left">escala</th>
                  <th class="px-2 py-1 text-left">orden</th>
                  <th class="px-2 py-1 text-left">Es visible</th>
                  <th class="px-2 py-1"></th>
                </tr>
              </thead>
              <tbody>
                <%= for {componente, idx} <- Enum.with_index(@componentes) do %>
                  <tr class="border-b border-gray-200">
                    <td class="px-2 py-1">
                      <input type="text" name={"componentes[#{idx}][nombre]"} value={componente["nombre"]} required
                        pattern="[a-z][a-z0-9_]*" maxlength="50"
                        title="Minúsculas, sin acentos ni espacios. Letras, números y guion_bajo, debe empezar con una letra."
                        class="border border-gray-300 rounded text-gray-900 px-2 py-1 w-32" placeholder="pty_carro_nombre" />
                    </td>
                    <td class="px-2 py-1">
                      <input type="text" name={"componentes[#{idx}][etiqueta]"} value={componente["etiqueta"]} required maxlength="100"
                        class="border border-gray-300 rounded text-gray-900 px-2 py-1 w-28" placeholder="Nombre" />
                    </td>
                    <td class="px-2 py-1">
                      <select name={"componentes[#{idx}][tipo]"} class="border border-gray-300 rounded text-gray-900 px-2 py-1">
                        <%= for tipo <- @tipos do %>
                          <option value={tipo} selected={componente["tipo"] == tipo}>{tipo}</option>
                        <% end %>
                      </select>
                    </td>
                    <td class="px-2 py-1">
                      <input type="number" name={"componentes[#{idx}][longitud]"} value={componente["longitud"]}
                        class="border border-gray-300 rounded text-gray-900 px-2 py-1 w-16" />
                    </td>
                    <td class="px-2 py-1">
                      <input type="number" name={"componentes[#{idx}][precision]"} value={componente["precision"]}
                        class="border border-gray-300 rounded text-gray-900 px-2 py-1 w-16" />
                    </td>
                    <td class="px-2 py-1">
                      <input type="number" name={"componentes[#{idx}][escala]"} value={componente["escala"]}
                        class="border border-gray-300 rounded text-gray-900 px-2 py-1 w-16" />
                    </td>
                    <td class="px-2 py-1">
                      <input type="number" name={"componentes[#{idx}][orden]"} value={componente["orden"]}
                        class="border border-gray-300 rounded text-gray-900 px-2 py-1 w-14" />
                    </td>
                    <td class="px-2 py-1">
                      <input type="hidden" name={"componentes[#{idx}][visible]"} value="false" />
                      <input type="checkbox" name={"componentes[#{idx}][visible]"} value="true" checked={componente["visible"] == true} />
                    </td>
                    <td class="px-2 py-1">
                      <button type="button" phx-click="quitar_componente" phx-value-idx={idx}
                        class="text-red-600 text-xs font-semibold">Quitar</button>
                    </td>
                  </tr>
                <% end %>
              </tbody>
            </table>
            <button type="button" phx-click="agregar_componente" class="mt-3 text-sm font-semibold text-purple-700">
              + Agregar componente
            </button>
          </div>
        </fieldset>
        <% end %>

        <div class="flex justify-end gap-3">
          <button type="button" phx-click="cancelar" class="bg-red-500 hover:bg-red-600 text-white font-bold px-8 py-2 rounded">
            Cancelar
          </button>
          <button type="submit" class="bg-green-500 hover:bg-green-600 text-white font-bold px-8 py-2 rounded">
            Guardar
          </button>
        </div>
      </form>
    </div>
    </div>
    """
  end
end
