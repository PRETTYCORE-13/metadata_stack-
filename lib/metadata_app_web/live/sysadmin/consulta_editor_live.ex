defmodule MetadataAppWeb.Sysadmin.ConsultaEditorLive do
  # Editor mínimo de una Consulta Ecto (schema_context_type: 3) — a
  # diferencia de BcMotorLive (campos/estados/transiciones/reglas de un
  # catálogo real), acá solo hay una cosa que editar: qué campos expone el
  # reporte, con qué etiqueta, si son visibles (Get View) y si se totalizan
  # al pie de la tabla. Sin estados, sin TRN, sin motor — ver
  # MetadataApp.MetaConsultas para el resto del contrato.
  use MetadataAppWeb, :live_view_admin

  on_mount {MetadataAppWeb.UsuarioAuth, :mount_current_scope}
  on_mount {MetadataAppWeb.Hooks.Autorizacion, {"sysadmin_bc", "editar"}}

  alias MetadataApp.BusinessProcessBuilder.MetaSchemaContext
  alias MetadataApp.MetaConsultas
  alias MetadataAppWeb.AdminNav

  @menu [
    %{tipo: :pagina, id: "bc_list", label: "BC List", nav: "/sysadmin/bc-list"},
    %{tipo: :pagina, id: "buscar_trn", label: "Buscar TRN", nav: "/sysadmin/buscar-trn"},
    %{tipo: :pagina, id: "roles", label: "Roles y Usuarios", nav: "/sysadmin/roles"},
    %{tipo: :pagina, id: "usuarios_empresa", label: "Usuarios", nav: "/sysadmin/usuarios"},
    %{tipo: :pagina, id: "empresas", label: "Empresas", nav: "/sysadmin/empresas"}
  ]

  # Solo estos dos tipos soportan SUM() en SQL (ver totales/2 en
  # MetaConsultas) — "totalizar" ni se ofrece para el resto, para no dejar
  # marcar algo que reventaría la query de la banda de totales al ejecutar
  # el reporte.
  @tipos_totalizables ~w(integer decimal)

  def mount(%{"nombre" => nombre}, _session, socket) do
    socket =
      socket
      |> assign(:current_page, "bc_list")
      |> assign(:menu_items, AdminNav.filtrar_menu(@menu))
      |> assign(:sidebar_open, false)
      |> assign(:show_programacion_children, false)
      |> assign(:show_clientes_children, false)
      |> assign(:show_prettycore_children, false)
      |> assign(:tipos_totalizables, @tipos_totalizables)

    case MetaSchemaContext.obtener_header_por_nombre(nombre) do
      %{schema_context_type: 3} = header ->
        {:ok, cargar(socket, header)}

      _otro ->
        {:ok,
         socket
         |> put_flash(:error, "Esa consulta no existe.")
         |> push_navigate(to: ~p"/sysadmin/bc-list")}
    end
  end

  defp cargar(socket, header) do
    consulta = MetaConsultas.obtener_por_header_id(header.id)
    campos = Enum.sort_by(consulta.campos, &Map.get(&1, "orden", 0))

    socket
    |> assign(:header, header)
    |> assign(:consulta, consulta)
    |> assign(:campos, campos)
    |> assign(:multi_tabla?, consulta.joins != [])
  end

  def handle_event("change_page", %{"id" => id}, socket) do
    AdminNav.handle_nav(id, socket, "bc_list")
  end

  # Reordena por intercambio simple con el vecino — sin drag-and-drop, se
  # persiste al toque (no forma parte del form de "Guardar" de abajo) para
  # que el orden de la lista no dependa de acordarse de guardar aparte.
  def handle_event("mover_campo", %{"campo" => id, "direccion" => direccion}, socket) do
    indice = Enum.find_index(socket.assigns.campos, &(identificador(&1) == id))
    vecino = if direccion == "arriba", do: indice - 1, else: indice + 1

    if indice && vecino >= 0 && vecino < length(socket.assigns.campos) do
      campos = intercambiar_orden(socket.assigns.campos, indice, vecino)

      case MetaConsultas.actualizar_campos(socket.assigns.consulta, campos) do
        {:ok, consulta} ->
          {:noreply, socket |> assign(:consulta, consulta) |> assign(:campos, Enum.sort_by(campos, &Map.get(&1, "orden", 0)))}

        {:error, _changeset} ->
          {:noreply, put_flash(socket, :error, "No se pudo reordenar.")}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("guardar_campos", params, socket) do
    etiquetas = Map.get(params, "etiquetas", %{})
    visibles = params |> Map.get("visibles", []) |> List.wrap() |> MapSet.new()
    totalizar = params |> Map.get("totalizar", []) |> List.wrap() |> MapSet.new()

    campos =
      Enum.map(socket.assigns.campos, fn campo ->
        id = identificador(campo)
        tipo = campo["tipo"]

        etiqueta =
          case Map.get(etiquetas, id) do
            texto when is_binary(texto) and texto != "" -> texto
            _ -> campo["etiqueta"]
          end

        campo
        |> Map.put("etiqueta", etiqueta)
        |> Map.put("visible", id in visibles)
        |> Map.put("totalizar", tipo in @tipos_totalizables and id in totalizar)
      end)

    case MetaConsultas.actualizar_campos(socket.assigns.consulta, campos) do
      {:ok, consulta} ->
        {:noreply,
         socket
         |> assign(:consulta, consulta)
         |> assign(:campos, Enum.sort_by(campos, &Map.get(&1, "orden", 0)))
         |> put_flash(:info, "Consulta actualizada.")}

      {:error, changeset} ->
        {:noreply, put_flash(socket, :error, "No se pudo guardar: #{inspect(changeset.errors)}")}
    end
  end

  # Identificador único de una fila — dos tablas distintas de la misma
  # consulta pueden tener un campo con el mismo nombre crudo (ej. ambas
  # con "nombre"), así que ni los eventos (mover_campo) ni los <input>
  # del form de abajo pueden usar campo["campo"] solo: "::" no es válido
  # en un nombre de catálogo o de campo, así que nunca puede colisionar.
  defp identificador(campo), do: "#{campo["catalogo"]}::#{campo["campo"]}"

  defp intercambiar_orden(campos, i, j) do
    a = Enum.at(campos, i)
    b = Enum.at(campos, j)

    campos
    |> List.replace_at(i, Map.put(a, "orden", b["orden"]))
    |> List.replace_at(j, Map.put(b, "orden", a["orden"]))
  end

  def render(assigns) do
    ~H"""
    <div class="p-6 max-w-4xl mx-auto">
      <div class="flex items-center justify-between mb-4">
        <div>
          <h1 class="text-xl font-bold text-gray-900 flex items-center gap-2">
            <span class="material-symbols-outlined text-purple-600">search</span>
            {@header.schema_context_label}
          </h1>
          <p class="text-xs text-gray-500 mt-1">
            Consulta Ecto de solo lectura sobre <strong>{Enum.join(MetaConsultas.catalogos_presentes(@consulta), " + ")}</strong> — {@header.schema_context_nav}
          </p>
        </div>
        <.link navigate={@header.schema_context_nav} class="text-xs font-semibold text-purple-700 hover:underline">
          Ver reporte →
        </.link>
      </div>

      <form phx-submit="guardar_campos" class="bg-white border border-gray-200 rounded-2xl shadow-sm">
        <div class="overflow-x-auto rounded-t-2xl">
          <table class="min-w-full divide-y divide-gray-200 text-xs">
            <thead class="bg-gray-50">
              <tr>
                <th class="px-3 py-2 text-left font-semibold text-gray-500 uppercase tracking-wide">Orden</th>
                <th :if={@multi_tabla?} class="px-3 py-2 text-left font-semibold text-gray-500 uppercase tracking-wide">Tabla</th>
                <th class="px-3 py-2 text-left font-semibold text-gray-500 uppercase tracking-wide">Campo</th>
                <th class="px-3 py-2 text-left font-semibold text-gray-500 uppercase tracking-wide">Etiqueta</th>
                <th class="px-3 py-2 text-center font-semibold text-gray-500 uppercase tracking-wide">Visible</th>
                <th class="px-3 py-2 text-center font-semibold text-gray-500 uppercase tracking-wide">Totalizar</th>
              </tr>
            </thead>
            <tbody class="divide-y divide-gray-100">
              <tr :for={{campo, indice} <- Enum.with_index(@campos)}>
                <td class="px-3 py-2">
                  <div class="flex flex-col">
                    <button type="button" disabled={indice == 0} phx-click="mover_campo" phx-value-campo={identificador(campo)} phx-value-direccion="arriba"
                      class="text-gray-400 hover:text-purple-700 disabled:opacity-20 disabled:cursor-not-allowed leading-none">▲</button>
                    <button type="button" disabled={indice == length(@campos) - 1} phx-click="mover_campo" phx-value-campo={identificador(campo)} phx-value-direccion="abajo"
                      class="text-gray-400 hover:text-purple-700 disabled:opacity-20 disabled:cursor-not-allowed leading-none">▼</button>
                  </div>
                </td>
                <td :if={@multi_tabla?} class="px-3 py-2 text-gray-500 font-mono">{campo["catalogo"]}</td>
                <td class="px-3 py-2 text-gray-500 font-mono">{campo["campo"]}</td>
                <td class="px-3 py-2">
                  <input type="text" name={"etiquetas[#{identificador(campo)}]"} value={campo["etiqueta"]}
                    class="w-full border border-gray-300 rounded px-2 py-1 text-gray-900" />
                </td>
                <td class="px-3 py-2 text-center">
                  <input type="checkbox" name="visibles[]" value={identificador(campo)} checked={campo["visible"]} class="accent-purple-600" />
                </td>
                <td class="px-3 py-2 text-center">
                  <input type="checkbox" name="totalizar[]" value={identificador(campo)} checked={campo["totalizar"]}
                    disabled={campo["tipo"] not in @tipos_totalizables}
                    title={if campo["tipo"] not in @tipos_totalizables, do: "Solo campos numéricos se pueden totalizar"}
                    class="accent-purple-600 disabled:opacity-20" />
                </td>
              </tr>
              <tr :if={@campos == []}>
                <td colspan={if @multi_tabla?, do: 6, else: 5} class="px-3 py-6 text-center text-gray-400">Esta consulta no tiene campos.</td>
              </tr>
            </tbody>
          </table>
        </div>

        <div class="px-4 py-3 border-t border-gray-200 flex justify-end">
          <button type="submit" class="px-4 py-2 rounded-lg bg-purple-600 text-white text-sm font-semibold hover:bg-purple-700">
            Guardar
          </button>
        </div>
      </form>
    </div>
    """
  end
end
