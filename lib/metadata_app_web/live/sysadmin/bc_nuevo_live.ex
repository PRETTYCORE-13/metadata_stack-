defmodule MetadataAppWeb.Sysadmin.BcNuevoLive do
  # Ventana emergente, sin el layout admin (sidebar/topbar) — solo el
  # formulario, así se ve limpio dentro de la ventana chica.
  use MetadataAppWeb, :live_view

  alias MetadataApp.MetaSchemaContext
  alias MetadataApp.CatalogoGenerador

  @topic "bc_contextos"

  @tipos ~w(string integer decimal boolean date enum referencia)

  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:mensaje, nil)
     |> nuevo_formulario()}
  end

  # Sin esto el servidor nunca se entera de lo tecleado hasta el submit —
  # cualquier vuelta al servidor antes de eso (agregar/quitar fila) repinta
  # el formulario con los valores viejos y borra lo escrito.
  def handle_event("validar", %{"contexto" => contexto, "componentes" => componentes_map}, socket) do
    contexto = Map.put(contexto, "visible", contexto["visible"] == "true")

    componentes =
      componentes_map
      |> Enum.sort_by(fn {idx, _} -> String.to_integer(idx) end)
      |> Enum.map(fn {_idx, c} -> Map.put(c, "visible", c["visible"] == "true") end)

    {:noreply, socket |> assign(:contexto, contexto) |> assign(:componentes, componentes)}
  end

  def handle_event("agregar_componente", _params, socket) do
    componentes = socket.assigns.componentes ++ [componente_vacio(length(socket.assigns.componentes) + 1)]
    {:noreply, assign(socket, :componentes, componentes)}
  end

  def handle_event("quitar_componente", %{"idx" => idx}, socket) do
    idx = String.to_integer(idx)
    {:noreply, assign(socket, :componentes, List.delete_at(socket.assigns.componentes, idx))}
  end

  def handle_event("cancelar", _params, socket) do
    {:noreply, socket |> nuevo_formulario() |> assign(:mensaje, nil)}
  end

  def handle_event("guardar", %{"contexto" => contexto, "componentes" => componentes_map}, socket) do
    componentes =
      componentes_map
      |> Enum.sort_by(fn {idx, _} -> String.to_integer(idx) end)
      |> Enum.map(fn {_idx, c} -> c end)

    header_attrs = %{
      "schema_context_name" => contexto["nombre"],
      "schema_context_label" => contexto["etiqueta"],
      "schema_context_nav" => contexto["nav"],
      "schema_visible" => contexto["visible"] == "true",
      "detalles" => Enum.map(componentes, &detalle_attrs/1)
    }

    case MetaSchemaContext.crear_header_con_detalles(header_attrs) do
      {:ok, {header, _detalles}} ->
        resultado = CatalogoGenerador.generar(header.schema_context_name)

        texto =
          case resultado do
            {:ok, %{ya_existia: true}} -> "Contexto '#{header.schema_context_label}' guardado (el catálogo ya existía)."
            {:ok, _} -> "Contexto '#{header.schema_context_label}' guardado y catálogo generado."
            {:error, motivo} -> "Contexto guardado, pero no se pudo generar el catálogo: #{motivo}"
          end

        Phoenix.PubSub.broadcast(MetadataApp.PubSub, @topic, {:bc_creado, header})

        {:noreply,
         socket
         |> nuevo_formulario()
         |> assign(:mensaje, {:ok, texto})
         |> push_event("cerrar_ventana", %{})}

      {:error, changeset} ->
        {:noreply, assign(socket, :mensaje, {:error, resumen_errores(changeset)})}
    end
  end

  defp nuevo_formulario(socket) do
    socket
    |> assign(:contexto, %{"nombre" => "", "etiqueta" => "", "nav" => "", "visible" => true})
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
    assigns = assign(assigns, :tipos, @tipos)

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
            <label class="font-medium text-gray-900">Nombre de sistema:</label>
            <input type="text" name="contexto[nombre]" value={@contexto["nombre"]} required
              class="border border-gray-300 rounded text-gray-900 px-2 py-1" placeholder="pty_carros" />

            <label class="font-medium text-gray-900">Etiqueta:</label>
            <input type="text" name="contexto[etiqueta]" value={@contexto["etiqueta"]} required
              class="border border-gray-300 rounded text-gray-900 px-2 py-1" placeholder="Catálogo de carros" />

            <label class="font-medium text-gray-900">Navegación:</label>
            <input type="text" name="contexto[nav]" value={@contexto["nav"]} required
              class="border border-gray-300 rounded text-gray-900 px-2 py-1" placeholder="/catalogos/carros" />

            <label class="font-medium text-gray-900">Es visible:</label>
            <div>
              <input type="hidden" name="contexto[visible]" value="false" />
              <input type="checkbox" name="contexto[visible]" value="true" checked={@contexto["visible"] == true} />
            </div>
          </div>
        </fieldset>

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
                        class="border border-gray-300 rounded text-gray-900 px-2 py-1 w-32" placeholder="pty_carro_nombre" />
                    </td>
                    <td class="px-2 py-1">
                      <input type="text" name={"componentes[#{idx}][etiqueta]"} value={componente["etiqueta"]} required
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
