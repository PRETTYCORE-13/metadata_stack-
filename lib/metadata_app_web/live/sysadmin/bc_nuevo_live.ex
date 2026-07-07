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
    contexto =
      contexto
      |> Map.put("visible", contexto["visible"] == "true")
      |> Map.put("nombre_p2", normalizar_identificador(contexto["nombre_p2"]))
      |> Map.put("nombre_p3", normalizar_identificador(contexto["nombre_p3"]))

    componentes =
      componentes_map
      |> Enum.sort_by(fn {idx, _} -> String.to_integer(idx) end)
      |> Enum.map(fn {_idx, c} -> Map.put(c, "visible", c["visible"] == "true") end)

    {:noreply, socket |> assign(:contexto, contexto) |> assign(:componentes, componentes)}
  end

  # Mismo criterio de normalización, pero con el prefijo /catalogos/.
  def handle_event("normalizar_nav", %{"value" => valor}, socket) do
    nav_normalizado = normalizar_nav(valor)
    {:noreply, assign(socket, :contexto, Map.put(socket.assigns.contexto, "nav", nav_normalizado))}
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
    contexto =
      contexto
      |> Map.put("nombre", combinar_nombre_sistema(contexto["nombre_p2"], contexto["nombre_p3"]))
      |> Map.put("nav", normalizar_nav(contexto["nav"]))

    componentes =
      componentes_map
      |> Enum.sort_by(fn {idx, _} -> String.to_integer(idx) end)
      |> Enum.map(fn {_idx, c} -> c end)

    case validar_formulario(contexto, componentes) do
      :ok ->
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

      {:error, motivo} ->
        {:noreply, assign(socket, :mensaje, {:error, motivo})}
    end
  end

  # No basta con las restricciones del navegador (pattern/maxlength) — un
  # cliente HTTP directo a este LiveView se las salta. schema_context_name y
  # schema_context_field terminan siendo identificadores reales de Postgres
  # (nombre de tabla / nombre de columna), así que se validan aquí también.
  @identificador ~r/^[a-z][a-z0-9_]{0,49}$/
  @nav ~r/^\/[a-z0-9\-\/]{0,49}$/

  defp validar_formulario(contexto, componentes) do
    with :ok <- validar_regex(contexto["nombre"], @identificador, "Nombre de sistema"),
         :ok <- validar_regex(contexto["nav"], @nav, "Navegación"),
         :ok <- validar_completado(contexto["nav"], "/catalogos/", "Navegación"),
         :ok <- validar_completado(contexto["etiqueta"], "Catálogo de", "Etiqueta") do
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

  # minúsculas + sin acentos/espacios + siempre con una sola barra inicial.
  # "catalogos/" es solo el valor por default del campo — es editable, si el
  # usuario lo borra se queda borrado, no se vuelve a agregar solo.
  defp normalizar_nav(valor) do
    limpio =
      (valor || "")
      |> String.downcase()
      |> quitar_acentos()
      |> String.replace(~r/[^a-z0-9\-\/]/, "")

    resultado = if limpio == "", do: "", else: "/" <> String.trim_leading(limpio, "/")

    String.slice(resultado, 0, 50)
  end

  defp nuevo_formulario(socket) do
    socket
    |> assign(:contexto, %{
      "nombre_p2" => "catalogos",
      "nombre_p3" => "",
      "etiqueta" => "Catálogo de ",
      "nav" => "/catalogos/",
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

    assigns =
      assigns
      |> assign(:tipos, @tipos)
      |> assign(:nombre_sistema_preview, nombre_sistema)

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

            <label class="font-medium text-gray-900">Etiqueta:</label>
            <input type="text" name="contexto[etiqueta]" value={@contexto["etiqueta"]} required maxlength="100"
              class="border border-gray-300 rounded text-gray-900 px-2 py-1" placeholder="Catálogo de carros" />

            <label class="font-medium text-gray-900">Navegación:</label>
            <div>
              <input type="text" name="contexto[nav]" value={@contexto["nav"]} required maxlength="50"
                phx-blur="normalizar_nav"
                title="Se convierte solo a minúsculas al salir del campo. /catalogos/ es solo el valor por default, lo puedes editar o borrar libremente."
                class="border border-gray-300 rounded text-gray-900 px-2 py-1" placeholder="/catalogos/carros" />
              <div class="mt-1.5 bg-blue-600 text-white rounded px-2 py-1.5 text-xs inline-flex items-center gap-1.5">
                <span class="text-blue-100">Vista previa:</span>
                <span class="font-mono">
                  {@contexto["nav"]}<%= if @nombre_sistema_preview != "", do: "/#{@nombre_sistema_preview}" %>
                </span>
              </div>
            </div>

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
