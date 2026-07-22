defmodule MetadataAppWeb.Sysadmin.BuscadorTrnLive do
  # PrettyCore TRN, Fase 3 — buscador universal: pega un TRN
  # (VENT-260721-104537-4832) o un ULID (01K1AB7F...) y resuelve contra
  # meta_schema_transaction_registry al registro real, sea cual sea el
  # catálogo. A diferencia de CatalogoGenerico.obtener!/2 (que exige
  # is_nil(delete_guid)), acá se busca AUNQUE el registro ya esté
  # soft-deleted — un buscador de auditoría/trazabilidad tiene que poder
  # encontrar algo que ya no está activo, no solo lo que sigue vivo.
  use MetadataAppWeb, :live_view_admin

  import Ecto.Query
  alias MetadataApp.Repo
  alias MetadataApp.BusinessProcessBuilder.MetaSchemaContext
  alias MetadataApp.BusinessProcessBuilder.MetaSchema.Header
  alias MetadataApp.MetaSchema.TransicionEvento
  alias MetadataApp.MetaStateEngine

  @menu [
    %{tipo: :pagina, id: "bc_list", label: "BC List", nav: "/sysadmin/bc-list"},
    %{tipo: :pagina, id: "buscar_trn", label: "Buscar TRN", nav: "/sysadmin/buscar-trn"}
  ]

  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:current_page, "buscar_trn")
     |> assign(:menu_items, @menu)
     |> assign(:sidebar_open, false)
     |> assign(:query, "")
     |> assign(:resultado, nil)
     |> assign(:error, nil)}
  end

  # El buscador compacto del topbar (menu_layout.ex) navega vía GET a
  # ?query=..., por eso la búsqueda se dispara acá y no en un
  # handle_event — así funciona sin importar desde qué pantalla se
  # llegó a través del layout compartido.
  def handle_params(%{"query" => query}, _uri, socket) when query != "" do
    {:noreply, buscar(socket, query)}
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  defp buscar(socket, query) do
    query = String.trim(query)

    {resultado, error} =
      case resolver(query) do
        {:ok, resultado} -> {resultado, nil}
        {:error, motivo} -> {nil, motivo}
      end

    socket |> assign(:query, query) |> assign(:resultado, resultado) |> assign(:error, error)
  end

  defp resolver(""), do: {:error, "Escribí un TRN (ej. VENT-260721-104537-4832) o un ULID para buscar."}

  defp resolver(query) do
    case buscar_en_registro(query) do
      nil ->
        {:error, "No se encontró ningún TRN/ULID que coincida con \"#{query}\"."}

      fila ->
        case Repo.get(Header, fila.meta_schema_header_id) do
          nil -> {:error, "Ese TRN existe en el historial, pero el catálogo al que pertenecía ya no existe (fue borrado por completo)."}
          header -> armar_resultado(fila, header)
        end
    end
  end

  defp buscar_en_registro(query) do
    Repo.one(
      from t in "meta_schema_transaction_registry",
        where: t.trn == ^query or t.ulid == ^query,
        select: %{
          trn: t.trn,
          ulid: t.ulid,
          meta_schema_header_id: t.meta_schema_header_id,
          entity_id: t.entity_id,
          creado_en: t.inserted_at
        }
    )
  end

  defp armar_resultado(fila, header) do
    modulo = MetaSchemaContext.modulo_por_nombre(header.schema_context_name)
    registro = modulo && Repo.get(modulo, fila.entity_id)

    {:ok,
     %{
       trn: fila.trn,
       ulid: fila.ulid,
       creado_en: fila.creado_en,
       header: header,
       registro: registro,
       activo?: registro != nil and is_nil(registro.delete_guid),
       campos: if(registro, do: MetaSchemaContext.listar_detalles(header.schema_context_name), else: []),
       estado_nombre: estado_nombre(header, registro),
       historial: listar_historial(header.id, fila.entity_id, header.schema_context_name)
     }}
  end

  defp estado_nombre(_header, nil), do: nil
  defp estado_nombre(_header, %{estado_id: nil}), do: nil

  defp estado_nombre(header, %{estado_id: estado_id}) do
    header.schema_context_name |> MetaStateEngine.mapa_nombres_estados() |> Map.get(estado_id)
  end

  defp listar_historial(meta_schema_header_id, registro_id, catalogo) do
    estados_por_id = MetaStateEngine.mapa_nombres_estados(catalogo)

    from(ev in TransicionEvento,
      where: ev.meta_schema_header_id == ^meta_schema_header_id and ev.registro_id == ^registro_id,
      order_by: [asc: ev.inserted_at]
    )
    |> Repo.all()
    |> Enum.map(fn ev ->
      %{
        accion: ev.accion,
        origen: Map.get(estados_por_id, ev.estado_origen_id) || "— (alta)",
        destino: Map.get(estados_por_id, ev.estado_destino_id) || "?",
        fecha: ev.inserted_at
      }
    end)
  end

  defp valor_campo(registro, campo) do
    Map.get(registro, String.to_existing_atom(campo.schema_context_field))
  end

  defp formatear_fecha(nil), do: "—"
  defp formatear_fecha(fecha), do: Calendar.strftime(fecha, "%Y-%m-%d %H:%M:%S UTC")

  def render(assigns) do
    ~H"""
    <div class="max-w-3xl mx-auto p-6 text-xs font-sans space-y-4">
      <div :if={@error} class="bg-red-50 border border-red-200 text-red-700 rounded-lg px-3 py-2">
        {@error}
      </div>

      <.resultado :if={@resultado} resultado={@resultado} />
    </div>
    """
  end

  attr :resultado, :map, required: true

  defp resultado(assigns) do
    ~H"""
    <div class="space-y-4">
      <div class="border border-gray-200 rounded-lg p-3 space-y-1.5">
        <div class="flex items-center justify-between">
          <span class="font-mono text-sm font-bold text-purple-700">{@resultado.trn}</span>
          <span :if={!@resultado.activo?} class="px-2 py-0.5 rounded-full bg-red-50 text-red-700 font-semibold">
            {if @resultado.registro, do: "Borrado (soft-delete)", else: "Registro no encontrado"}
          </span>
          <span :if={@resultado.activo?} class="px-2 py-0.5 rounded-full bg-green-50 text-green-700 font-semibold">Activo</span>
        </div>
        <p class="text-gray-500">
          ULID: <span class="font-mono">{@resultado.ulid}</span>
          <span class="mx-1.5 text-gray-300">·</span>
          Generado: {formatear_fecha(@resultado.creado_en)}
        </p>
        <p class="text-gray-500">
          Catálogo: <strong class="text-gray-900">{@resultado.header.schema_context_label}</strong>
          <span class="font-mono">({@resultado.header.schema_context_name})</span>
          <.link navigate={@resultado.header.schema_context_nav} class="ml-2 text-blue-600 hover:text-blue-800 font-semibold">
            Ver catálogo →
          </.link>
        </p>
        <p :if={@resultado.estado_nombre} class="text-gray-500">
          Estado actual: <strong class="text-gray-900">{@resultado.estado_nombre}</strong>
        </p>
      </div>

      <div :if={@resultado.registro} class="border border-gray-200 rounded-lg">
        <div class="px-1.5 ml-2 -mb-2 relative">
          <span class="bg-white px-1.5 font-bold uppercase tracking-wide text-[11px] text-gray-500">Datos del registro</span>
        </div>
        <div class="p-3 pt-4 overflow-x-auto">
          <table class="min-w-full">
            <tbody>
              <%= for campo <- @resultado.campos do %>
                <tr class="border-b border-gray-100">
                  <td class="px-1.5 py-1 text-gray-500 font-semibold whitespace-nowrap">{campo.schema_context_properties["etiqueta"]}</td>
                  <td class="px-1.5 py-1 text-gray-900">{valor_campo(@resultado.registro, campo)}</td>
                </tr>
              <% end %>
            </tbody>
          </table>
        </div>
      </div>

      <div :if={@resultado.historial != []} class="border border-gray-200 rounded-lg">
        <div class="px-1.5 ml-2 -mb-2 relative">
          <span class="bg-white px-1.5 font-bold uppercase tracking-wide text-[11px] text-gray-500">Historial</span>
        </div>
        <div class="p-3 pt-4 overflow-x-auto">
          <table class="min-w-full">
            <thead class="bg-gray-50">
              <tr>
                <th class="px-1.5 py-1 text-left font-semibold uppercase tracking-wide text-[11px] text-gray-500 border-b border-gray-200">Acción</th>
                <th class="px-1.5 py-1 text-left font-semibold uppercase tracking-wide text-[11px] text-gray-500 border-b border-gray-200">Origen → Destino</th>
                <th class="px-1.5 py-1 text-left font-semibold uppercase tracking-wide text-[11px] text-gray-500 border-b border-gray-200">Fecha</th>
              </tr>
            </thead>
            <tbody>
              <%= for evento <- @resultado.historial do %>
                <tr class="border-b border-gray-100">
                  <td class="px-1.5 py-1 text-gray-900 font-mono">{evento.accion}</td>
                  <td class="px-1.5 py-1 text-gray-600">{evento.origen} <span class="text-gray-300 mx-1">→</span> {evento.destino}</td>
                  <td class="px-1.5 py-1 text-gray-600">{formatear_fecha(evento.fecha)}</td>
                </tr>
              <% end %>
            </tbody>
          </table>
        </div>
      </div>
    </div>
    """
  end
end
