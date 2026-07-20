defmodule MetadataAppWeb.Sysadmin.BcMotorLive do
  # Plan de UI del Motor de Estados, construido por fases (ver memoria del
  # proyecto): Fase 2 (Estados + panel de salud), Fase 3 (Transiciones),
  # Fase 4 (diagrama Mermaid) — las tres de solo lectura. Fase 5 (acá) suma
  # la primera escritura real: agregar/quitar Reglas sobre transiciones que
  # YA existen. Sigue sin haber wizard de creación completa (eso usa
  # MetaEstadosAdmin.crear_proceso_completo/1, Fase 1, atómico) ni edición
  # de Estados/Transiciones en sí — eso queda para después.
  use MetadataAppWeb, :live_view_admin

  alias MetadataApp.BusinessProcessBuilder.MetaSchemaContext
  alias MetadataApp.MetaEstadosAdmin

  @menu [
    %{tipo: :pagina, id: "bc_list", label: "BC List", nav: "/sysadmin/bc-list"}
  ]

  def mount(%{"nombre" => nombre}, _session, socket) do
    socket =
      socket
      |> assign(:current_page, "bc_list")
      |> assign(:menu_items, @menu)
      |> assign(:sidebar_open, false)
      |> assign(:regla_form, nil)
      |> assign(:header, MetaSchemaContext.obtener_header_por_nombre(nombre))

    {:ok, cargar_motor(socket)}
  end

  defp cargar_motor(%{assigns: %{header: nil}} = socket), do: socket

  defp cargar_motor(%{assigns: %{header: header}} = socket) do
    {:ok, completitud} = MetaEstadosAdmin.completitud(header.schema_context_name)
    {:ok, validacion} = MetaEstadosAdmin.validar_motor(header.schema_context_name)
    estados = MetaEstadosAdmin.listar_estados(header.id)
    transiciones = MetaEstadosAdmin.listar_transiciones(header.id)

    socket
    |> assign(:estados, estados)
    |> assign(:estados_por_id, Map.new(estados, &{&1.id, &1}))
    |> assign(:transiciones, transiciones)
    |> assign(:diagrama, diagrama_mermaid(estados, transiciones))
    |> assign(:completitud, completitud)
    |> assign(:validacion, validacion)
  end

  # --- Reglas: vocabulario cerrado --------------------------------------------

  def handle_event("abrir_form_regla", %{"transicion_id" => id, "accion" => accion}, socket) do
    {:noreply,
     assign(socket, :regla_form, %{
       transicion_id: String.to_integer(id),
       accion: accion,
       regla: nil,
       error: nil
     })}
  end

  def handle_event("cerrar_form_regla", _params, socket) do
    {:noreply, assign(socket, :regla_form, nil)}
  end

  def handle_event("elegir_regla", %{"regla" => nombre}, socket) do
    nombre = if nombre == "", do: nil, else: nombre
    {:noreply, update(socket, :regla_form, &Map.put(&1, :regla, nombre))}
  end

  def handle_event("guardar_regla", %{"regla" => nombre} = params, socket) do
    case Map.fetch(MetaEstadosAdmin.vocabulario(), nombre) do
      {:ok, {tipo, _requeridos}} ->
        attrs = %{
          "transicion_id" => socket.assigns.regla_form.transicion_id,
          "tipo" => tipo,
          "regla" => nombre,
          "params" => normalizar_params_regla(nombre, Map.get(params, "params", %{})),
          "orden" => 0
        }

        case MetaEstadosAdmin.crear_regla(attrs) do
          {:ok, _regla} ->
            {:noreply,
             socket
             |> assign(:regla_form, nil)
             |> put_flash(:info, "Regla \"#{nombre}\" agregada.")
             |> cargar_motor()}

          {:error, changeset} ->
            {:noreply, update(socket, :regla_form, &Map.put(&1, :error, resumen_errores(changeset)))}
        end

      :error ->
        {:noreply, update(socket, :regla_form, &Map.put(&1, :error, "Elegí una regla de la lista."))}
    end
  end

  # --- Reglas: eliminar (vocabulario o de negocio) ----------------------------

  def handle_event("eliminar_regla", %{"id" => id}, socket) do
    id = String.to_integer(id)
    regla = socket.assigns.transiciones |> Enum.flat_map(& &1.reglas) |> Enum.find(&(&1.id == id))

    resultado = regla && MetaEstadosAdmin.eliminar_regla(regla)

    case resultado do
      {:ok, _} ->
        {:noreply, socket |> put_flash(:info, "Regla eliminada.") |> cargar_motor()}

      _ ->
        {:noreply, put_flash(socket, :error, "No se pudo eliminar la regla.")}
    end
  end

  # --- Reglas: de negocio (andamiaje) -----------------------------------------

  def handle_event("andamiar_negocio", %{"transicion_id" => id, "tipo" => tipo}, socket) do
    id = String.to_integer(id)
    transicion = Enum.find(socket.assigns.transiciones, &(&1.id == id))
    catalogo = socket.assigns.header.schema_context_name

    case transicion && MetaEstadosAdmin.andamiar_regla_negocio(catalogo, transicion, tipo) do
      {:ok, %{creado?: true, ruta: ruta}} ->
        {:noreply,
         socket
         |> put_flash(:info, "Stub creado y enganchado en #{ruta} — hay que completarlo en el editor de código.")
         |> cargar_motor()}

      {:ok, %{creado?: false, ruta: ruta}} ->
        {:noreply,
         socket
         |> put_flash(:info, "El archivo #{ruta} ya existía, solo se enganchó.")
         |> cargar_motor()}

      {:error, :ya_tiene_regla} ->
        {:noreply, put_flash(socket, :error, "Esa transición ya tiene una regla #{tipo}.")}

      _ ->
        {:noreply, put_flash(socket, :error, "No se pudo enganchar la regla de negocio.")}
    end
  end

  # campos_requeridos.campos: texto separado por coma -> lista, sin vacíos.
  defp normalizar_params_regla("campos_requeridos", %{"campos" => campos}) do
    lista = campos |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
    %{"campos" => lista}
  end

  # mutar_relacionados.cambio es un mapa anidado {campo, valor} — el form
  # manda dos campos sueltos (cambio_campo/cambio_valor) que se combinan acá,
  # más simple que inventar una notación de objeto anidado en un <input>.
  defp normalizar_params_regla(
         "mutar_relacionados",
         %{"entidad" => entidad, "campo_relacion" => cr, "cambio_campo" => cc, "cambio_valor" => cv}
       ) do
    %{"entidad" => entidad, "campo_relacion" => cr, "cambio" => %{"campo" => cc, "valor" => cv}}
  end

  defp normalizar_params_regla(_regla, params), do: params

  defp resumen_errores(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {k, v}, acc -> String.replace(acc, "%{#{k}}", to_string(v)) end)
    end)
    |> inspect()
  end

  # --- Render ------------------------------------------------------------------

  def render(%{header: nil} = assigns) do
    ~H"""
    <div class="max-w-3xl mx-auto p-8">
      <p class="text-sm text-gray-600">Ese catálogo ya no existe (puede que alguien más lo haya borrado).</p>
    </div>
    """
  end

  def render(assigns) do
    ~H"""
    <div class="max-w-4xl mx-auto p-6 text-xs font-sans space-y-4">
      <div>
        <h1 class="text-lg font-bold text-gray-900">{@header.schema_context_label}</h1>
        <p class="mt-0.5 text-gray-500">
          <span class="font-mono">{@header.schema_context_name}</span>
          <span class="mx-1.5 text-gray-300">·</span>
          <span class="font-mono">{@header.schema_context_nav}</span>
        </p>
      </div>

      <div class="bg-amber-50 border border-amber-200 text-amber-800 rounded-lg px-3 py-2">
        Estados/Transiciones/diagrama son de solo lectura todavía. Reglas ya se pueden agregar/quitar acá.
      </div>

      <.panel_salud completitud={@completitud} validacion={@validacion} />
      <.tabla_estados estados={@estados} />
      <.diagrama_transiciones diagrama={@diagrama} />
      <.tabla_transiciones transiciones={@transiciones} estados_por_id={@estados_por_id} catalogo={@header.schema_context_name} />
    </div>

    <.modal_regla :if={@regla_form} form={@regla_form} vocabulario={MetaEstadosAdmin.vocabulario()} />
    """
  end

  # Genera la definición Mermaid (stateDiagram-v2) del autómata — un [*] por
  # cada estado inicial y por cada transición sin estado_origen ("alta"),
  # más un arco por transición. Los nombres de estado se declaran con alias
  # cortos (e1, e2...) en vez de usarlos directo como id del nodo: soporta
  # cualquier nombre con espacios/acentos sin arriesgar la sintaxis de
  # Mermaid, que es estricta con los identificadores de nodo.
  defp diagrama_mermaid(estados, transiciones) do
    alias_por_id = estados |> Enum.with_index(1) |> Map.new(fn {e, i} -> {e.id, "e#{i}"} end)

    declaraciones =
      Enum.map(estados, fn e -> ~s(    state "#{escapar_mermaid(e.nombre)}" as #{Map.fetch!(alias_por_id, e.id)}) end)

    iniciales =
      estados
      |> Enum.filter(& &1.es_inicial)
      |> Enum.map(&"    [*] --> #{Map.fetch!(alias_por_id, &1.id)}")

    arcos =
      Enum.map(transiciones, fn t ->
        origen = if t.estado_origen_id, do: Map.get(alias_por_id, t.estado_origen_id, "?"), else: "[*]"
        destino = Map.get(alias_por_id, t.estado_destino_id, "?")
        "    #{origen} --> #{destino} : #{escapar_mermaid(t.accion)}"
      end)

    (["stateDiagram-v2"] ++ declaraciones ++ iniciales ++ arcos) |> Enum.join("\n")
  end

  defp escapar_mermaid(texto), do: String.replace(texto || "", "\"", "")

  attr :completitud, :map, required: true
  attr :validacion, :map, required: true

  defp panel_salud(assigns) do
    ~H"""
    <div class="border border-gray-200 rounded-lg">
      <div class="px-1.5 ml-2 -mb-2 relative">
        <span class="bg-white px-1.5 font-bold uppercase tracking-wide text-[11px] text-gray-500">Estado del motor</span>
      </div>
      <div class="p-3 pt-4 space-y-3">
        <div class="grid grid-cols-2 gap-2">
          <.chequeo ok={@completitud.tiene_campos} texto="Tiene campos" />
          <.chequeo ok={@completitud.tiene_estados} texto="Tiene estados" />
          <.chequeo ok={@completitud.tiene_alta_o_inicial} texto="Tiene alta o estado inicial" />
          <.chequeo ok={@completitud.transiciones_self_loop_sin_campos_editables == 0} texto="Self-loops con campos_editables" />
        </div>

        <div class="flex items-center gap-3 text-gray-600">
          <span>Reglas: {@completitud.reglas.total} total</span>
          <span>·</span>
          <span>{@completitud.reglas.vocabulario_cerrado} vocabulario cerrado</span>
          <span>·</span>
          <span>{@completitud.reglas.negocio_completas} de negocio completas</span>
          <%= if @completitud.reglas.negocio_stub > 0 do %>
            <span class="text-amber-600 font-semibold">· {@completitud.reglas.negocio_stub} stub sin completar</span>
          <% end %>
        </div>

        <div class={[
          "rounded-lg px-2.5 py-1.5 font-semibold inline-flex items-center gap-1.5",
          @completitud.completo? && "bg-green-50 text-green-700",
          not @completitud.completo? && "bg-amber-50 text-amber-700"
        ]}>
          <span class="material-symbols-outlined" style="font-size: 14px">
            {if @completitud.completo?, do: "check_circle", else: "pending"}
          </span>
          {if @completitud.completo?, do: "Completo", else: "Incompleto / borrador"}
        </div>

        <%= if @validacion.problemas != [] do %>
          <div class="space-y-1 pt-1 border-t border-gray-100">
            <%= for problema <- @validacion.problemas do %>
              <div class={[
                "flex items-start gap-1.5 px-2 py-1 rounded",
                problema.severidad == :error && "bg-red-50 text-red-700",
                problema.severidad == :advertencia && "bg-amber-50 text-amber-700"
              ]}>
                <span class="font-bold uppercase text-[10px] pt-0.5">
                  {if problema.severidad == :error, do: "Error", else: "Aviso"}
                </span>
                <span>{problema.mensaje}</span>
              </div>
            <% end %>
          </div>
        <% else %>
          <p class="text-gray-400 pt-1 border-t border-gray-100">Sin problemas estructurales detectados.</p>
        <% end %>
      </div>
    </div>
    """
  end

  attr :ok, :boolean, required: true
  attr :texto, :string, required: true

  defp chequeo(assigns) do
    ~H"""
    <div class={["flex items-center gap-1.5", @ok && "text-green-700", not @ok && "text-gray-400"]}>
      <span class="material-symbols-outlined" style="font-size: 14px">{if @ok, do: "check_circle", else: "radio_button_unchecked"}</span>
      {@texto}
    </div>
    """
  end

  attr :estados, :list, required: true

  defp tabla_estados(assigns) do
    ~H"""
    <div class="border border-gray-200 rounded-lg">
      <div class="px-1.5 ml-2 -mb-2 relative">
        <span class="bg-white px-1.5 font-bold uppercase tracking-wide text-[11px] text-gray-500">Estados</span>
      </div>
      <div class="p-3 pt-4 overflow-x-auto">
        <%= if @estados == [] do %>
          <p class="text-gray-400">Este catálogo todavía no tiene estados definidos.</p>
        <% else %>
          <table class="min-w-full">
            <thead class="bg-gray-50">
              <tr>
                <th class="px-1.5 py-1 text-left font-semibold uppercase tracking-wide text-[11px] text-gray-500 border-b border-gray-200"></th>
                <th class="px-1.5 py-1 text-left font-semibold uppercase tracking-wide text-[11px] text-gray-500 border-b border-gray-200">Nombre</th>
                <th class="px-1.5 py-1 text-left font-semibold uppercase tracking-wide text-[11px] text-gray-500 border-b border-gray-200">Inicial</th>
                <th class="px-1.5 py-1 text-left font-semibold uppercase tracking-wide text-[11px] text-gray-500 border-b border-gray-200">Orden</th>
              </tr>
            </thead>
            <tbody>
              <%= for estado <- @estados do %>
                <tr class="border-b border-gray-100 hover:bg-gray-50">
                  <td class="px-1.5 py-1">
                    <%= if estado.icono do %>
                      <span class="material-symbols-outlined" style={"font-size: 16px; color: #{estado.color || "#6b7280"}"}>{estado.icono}</span>
                    <% else %>
                      <span class="inline-block w-2.5 h-2.5 rounded-full" style={"background: #{estado.color || "#d1d5db"}"}></span>
                    <% end %>
                  </td>
                  <td class="px-1.5 py-1 text-gray-900">{estado.nombre}</td>
                  <td class="px-1.5 py-1">
                    <%= if estado.es_inicial do %>
                      <span class="text-purple-700 font-semibold">Sí</span>
                    <% else %>
                      <span class="text-gray-400">—</span>
                    <% end %>
                  </td>
                  <td class="px-1.5 py-1 text-gray-600">{estado.orden}</td>
                </tr>
              <% end %>
            </tbody>
          </table>
        <% end %>
      </div>
    </div>
    """
  end

  attr :transiciones, :list, required: true
  attr :estados_por_id, :map, required: true
  attr :catalogo, :string, required: true

  defp tabla_transiciones(assigns) do
    ~H"""
    <div class="border border-gray-200 rounded-lg">
      <div class="px-1.5 ml-2 -mb-2 relative">
        <span class="bg-white px-1.5 font-bold uppercase tracking-wide text-[11px] text-gray-500">Transiciones</span>
      </div>
      <div class="p-3 pt-4 overflow-x-auto">
        <%= if @transiciones == [] do %>
          <p class="text-gray-400">Este catálogo todavía no tiene transiciones definidas.</p>
        <% else %>
          <table class="min-w-full">
            <thead class="bg-gray-50">
              <tr>
                <th class="px-1.5 py-1 text-left font-semibold uppercase tracking-wide text-[11px] text-gray-500 border-b border-gray-200">Acción</th>
                <th class="px-1.5 py-1 text-left font-semibold uppercase tracking-wide text-[11px] text-gray-500 border-b border-gray-200">Etiqueta</th>
                <th class="px-1.5 py-1 text-left font-semibold uppercase tracking-wide text-[11px] text-gray-500 border-b border-gray-200">Origen → Destino</th>
                <th class="px-1.5 py-1 text-left font-semibold uppercase tracking-wide text-[11px] text-gray-500 border-b border-gray-200">Campos editables</th>
                <th class="px-1.5 py-1 text-left font-semibold uppercase tracking-wide text-[11px] text-gray-500 border-b border-gray-200">Reglas</th>
              </tr>
            </thead>
            <tbody>
              <%= for t <- @transiciones do %>
                <% self_loop? = t.estado_origen_id != nil and t.estado_origen_id == t.estado_destino_id %>
                <% aviso? = self_loop? and t.campos_editables == [] %>
                <% tiene_pre? = Enum.any?(t.reglas, &(&1.tipo == "pre")) %>
                <% tiene_post? = Enum.any?(t.reglas, &(&1.tipo == "post")) %>
                <tr class={["border-b border-gray-100 hover:bg-gray-50 align-top", aviso? && "bg-amber-50/60"]}>
                  <td class="px-1.5 py-1.5 text-gray-900 font-mono">
                    {t.accion}
                    <%= if aviso? do %>
                      <span
                        class="material-symbols-outlined text-amber-600 align-middle"
                        style="font-size: 13px"
                        title="Self-loop sin campos_editables — cualquier intento de editar por acá va a fallar"
                      >warning</span>
                    <% end %>
                  </td>
                  <td class="px-1.5 py-1.5 text-gray-700">{t.etiqueta}</td>
                  <td class="px-1.5 py-1.5 text-gray-600">
                    {nombre_estado(@estados_por_id, t.estado_origen_id) || "— (alta)"}
                    <span class="text-gray-300 mx-1">→</span>
                    {nombre_estado(@estados_por_id, t.estado_destino_id) || "?"}
                  </td>
                  <td class="px-1.5 py-1.5 text-gray-600">
                    <%= if t.campos_editables == [] do %>
                      <span class="text-gray-300">—</span>
                    <% else %>
                      {Enum.join(t.campos_editables, ", ")}
                    <% end %>
                  </td>
                  <td class="px-1.5 py-1.5">
                    <div class="flex flex-wrap gap-1 mb-1.5">
                      <%= for r <- t.reglas do %>
                        <span
                          class={[
                            "inline-flex items-center gap-1 rounded px-1.5 py-0.5 text-[11px] font-mono",
                            r.tipo == "pre" && "bg-gray-100 text-gray-700",
                            r.tipo == "post" && "bg-purple-50 text-purple-700"
                          ]}
                          title={"#{r.tipo}: #{inspect(r.params)}"}
                        >
                          {r.regla}
                          <%= if MetaEstadosAdmin.stub_sin_completar?(@catalogo, r.regla) do %>
                            <span class="text-amber-600" title="Stub de andamiaje sin completar todavía">⏳</span>
                          <% end %>
                          <button
                            type="button"
                            phx-click="eliminar_regla"
                            phx-value-id={r.id}
                            data-confirm="¿Quitar esta regla de la transición?"
                            class="text-gray-400 hover:text-red-600 leading-none"
                          >×</button>
                        </span>
                      <% end %>
                    </div>

                    <div class="flex flex-wrap gap-2 text-[11px]">
                      <button
                        type="button"
                        phx-click="abrir_form_regla"
                        phx-value-transicion_id={t.id}
                        phx-value-accion={t.accion}
                        class="text-purple-700 hover:text-purple-900 font-semibold"
                      >+ Regla</button>

                      <%= if not tiene_pre? do %>
                        <button type="button" phx-click="andamiar_negocio" phx-value-transicion_id={t.id} phx-value-tipo="pre" class="text-gray-500 hover:text-gray-800 font-semibold">
                          + Negocio (pre)
                        </button>
                      <% end %>
                      <%= if not tiene_post? do %>
                        <button type="button" phx-click="andamiar_negocio" phx-value-transicion_id={t.id} phx-value-tipo="post" class="text-gray-500 hover:text-gray-800 font-semibold">
                          + Negocio (post)
                        </button>
                      <% end %>
                    </div>
                  </td>
                </tr>
              <% end %>
            </tbody>
          </table>
        <% end %>
      </div>
    </div>
    """
  end

  defp nombre_estado(_mapa, nil), do: nil
  defp nombre_estado(mapa, id), do: Map.get(mapa, id, %{nombre: "?"}).nombre

  attr :diagrama, :string, required: true

  # phx-update="ignore": una vez que el hook pinta el SVG de Mermaid adentro,
  # este contenedor queda congelado para LiveView — sin esto, cualquier
  # re-render de la página (ej. un flash) borraría el SVG ya renderizado, ya
  # que el servidor solo sabe de un <div> vacío con el data-diagrama.
  defp diagrama_transiciones(assigns) do
    ~H"""
    <div class="border border-gray-200 rounded-lg">
      <div class="px-1.5 ml-2 -mb-2 relative">
        <span class="bg-white px-1.5 font-bold uppercase tracking-wide text-[11px] text-gray-500">Diagrama</span>
      </div>
      <div class="p-3 pt-4">
        <div
          id="diagrama-motor"
          phx-hook="DiagramaMotor"
          phx-update="ignore"
          data-diagrama={@diagrama}
          class="flex items-center justify-center min-h-[80px] text-gray-400"
        >
          Cargando diagrama…
        </div>
      </div>
    </div>
    """
  end

  attr :form, :map, required: true
  attr :vocabulario, :map, required: true

  defp modal_regla(assigns) do
    ~H"""
    <div class="fixed inset-0 bg-black/40 flex items-center justify-center z-50">
      <div class="bg-white rounded-xl shadow-lg max-w-sm w-full p-4 text-xs">
        <h2 class="text-sm font-bold text-gray-900 mb-1">Agregar regla</h2>
        <p class="text-gray-500 mb-3">
          Transición <span class="font-mono">{@form.accion}</span> — vocabulario cerrado
        </p>

        <%= if @form.error do %>
          <div class="bg-red-50 text-red-700 rounded-lg px-2 py-1.5 mb-2">{@form.error}</div>
        <% end %>

        <form phx-submit="guardar_regla">
          <label class="block font-medium text-gray-900 mb-1">Regla</label>
          <select name="regla" phx-change="elegir_regla" class="w-full border border-gray-300 rounded-lg px-2 py-1.5 mb-3 focus:outline-none focus:ring-2 focus:ring-purple-500/40 focus:border-purple-500">
            <option value="">— Elegir —</option>
            <%= for {nombre, {tipo, _requeridos}} <- Enum.sort(@vocabulario) do %>
              <option value={nombre} selected={@form.regla == nombre}>{tipo} · {nombre}</option>
            <% end %>
          </select>

          <%= if @form.regla do %>
            <% {_tipo, requeridos} = Map.fetch!(@vocabulario, @form.regla) %>
            <div class="space-y-2 mb-3">
              <%= for campo <- requeridos do %>
                <.campo_param_regla regla={@form.regla} campo={campo} />
              <% end %>
            </div>
          <% end %>

          <div class="flex justify-end gap-2">
            <button type="button" phx-click="cerrar_form_regla" class="px-3 py-1.5 rounded-lg border border-gray-300 text-gray-700 font-semibold hover:bg-gray-50">
              Cancelar
            </button>
            <button type="submit" disabled={!@form.regla} class="px-3 py-1.5 rounded-lg bg-purple-600 text-white font-semibold hover:bg-purple-700 disabled:opacity-40 disabled:cursor-not-allowed">
              Guardar
            </button>
          </div>
        </form>
      </div>
    </div>
    """
  end

  attr :regla, :string, required: true
  attr :campo, :string, required: true

  defp campo_param_regla(%{regla: "campo_cumple", campo: "operador"} = assigns) do
    ~H"""
    <div>
      <label class="block text-gray-700 mb-0.5">operador</label>
      <select name="params[operador]" class="w-full border border-gray-300 rounded-lg px-2 py-1">
        <option value=">">&gt;</option>
        <option value=">=">&gt;=</option>
        <option value="<">&lt;</option>
        <option value="<=">&lt;=</option>
        <option value="==">==</option>
        <option value="!=">!=</option>
      </select>
    </div>
    """
  end

  defp campo_param_regla(%{regla: "mutar_relacionados", campo: "cambio"} = assigns) do
    ~H"""
    <div class="grid grid-cols-2 gap-2">
      <div>
        <label class="block text-gray-700 mb-0.5">cambio: campo</label>
        <input type="text" name="params[cambio_campo]" class="w-full border border-gray-300 rounded-lg px-2 py-1" />
      </div>
      <div>
        <label class="block text-gray-700 mb-0.5">cambio: valor</label>
        <input type="text" name="params[cambio_valor]" class="w-full border border-gray-300 rounded-lg px-2 py-1" />
      </div>
    </div>
    """
  end

  defp campo_param_regla(%{campo: "campos"} = assigns) do
    ~H"""
    <div>
      <label class="block text-gray-700 mb-0.5">campos (separados por coma)</label>
      <input type="text" name="params[campos]" placeholder="campo_a, campo_b" class="w-full border border-gray-300 rounded-lg px-2 py-1" />
    </div>
    """
  end

  defp campo_param_regla(assigns) do
    ~H"""
    <div>
      <label class="block text-gray-700 mb-0.5">{@campo}</label>
      <input type="text" name={"params[#{@campo}]"} class="w-full border border-gray-300 rounded-lg px-2 py-1" />
    </div>
    """
  end
end
