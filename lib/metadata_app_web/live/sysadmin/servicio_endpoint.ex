defmodule MetadataAppWeb.Sysadmin.ServicioEndpoint do
  @moduledoc """
  Contrato y Endpoint de un Servicio (Consulta SQL de uso "servicio",
  SPEC-SYS-2509202601 §11.6/§11.8, R53-R53.2), compartido por el editor
  de SQL View (`ConsultaSqlEditorLive`, solo en local) y la sección
  Servicios (`ServiciosLive`, en cualquier ambiente).

  El LiveView que lo use necesita en sus assigns `:header`,
  `:consulta_sql`, `:current_scope` y `:bpb_habilitado`; `cargar/1`
  agrega `:endpoint`, `:credenciales`, `:key_temporal` y
  `:endpoint_error`, y sus eventos (`eventos/0`) se delegan a
  `manejar/3`. Crear, publicar y eliminar el Endpoint solo en local
  (R53.2); las credenciales, en cualquier ambiente.
  """
  use Phoenix.Component

  import Phoenix.LiveView, only: [put_flash: 3]

  alias MetadataApp.{ConsultasSql, ConsultaEndpoints}

  @eventos ~w(crear_endpoint publicar_endpoint despublicar_endpoint eliminar_endpoint
              crear_credencial revocar_credencial regenerar_credencial ocultar_key)
  @eventos_solo_local ~w(crear_endpoint publicar_endpoint despublicar_endpoint eliminar_endpoint)

  @tipos [
    {"entero", "Entero"},
    {"decimal", "Decimal"},
    {"texto", "Texto"},
    {"fecha", "Fecha"},
    {"booleano", "Sí/No"},
    {"lista_enteros", "Lista de enteros"},
    {"lista_decimales", "Lista de decimales"}
  ]

  def eventos, do: @eventos
  def tipos, do: @tipos

  @doc "Etiqueta legible de un tipo de parámetro (\"lista_enteros\" -> \"Lista de enteros\")."
  def etiqueta_tipo(tipo) do
    case List.keyfind(@tipos, tipo, 0) do
      {_, etiqueta} -> etiqueta
      nil -> tipo
    end
  end

  @doc "Default de un parámetro como texto de formulario."
  def default_a_texto(nil), do: ""
  def default_a_texto(lista) when is_list(lista), do: Enum.join(lista, ",")
  def default_a_texto(valor), do: to_string(valor)

  @doc "Carga el Endpoint del Servicio (si tiene) y sus credenciales."
  def cargar(socket) do
    consulta_sql = socket.assigns.consulta_sql

    endpoint =
      if consulta_sql.uso == "servicio", do: ConsultasSql.endpoint_del_servicio(consulta_sql)

    socket
    |> assign(:endpoint, endpoint)
    |> assign(
      :credenciales,
      if(endpoint, do: ConsultaEndpoints.listar_credenciales(endpoint.id), else: [])
    )
    |> assign_new(:key_temporal, fn -> nil end)
    |> assign_new(:endpoint_error, fn -> nil end)
  end

  @doc "Maneja un evento de `eventos/0`. Devuelve `{:noreply, socket}`."
  def manejar(evento, _params, %{assigns: %{bpb_habilitado: false}} = socket)
      when evento in @eventos_solo_local do
    {:noreply,
     put_flash(socket, :error, "Esto solo se puede editar en local (Business Process Builder).")}
  end

  def manejar("crear_endpoint", %{"endpoint" => params}, socket) do
    attrs = %{
      "nombre" => params["nombre"],
      "ruta" => params["ruta"],
      "metodo" => "post",
      "empresa_id" => socket.assigns.current_scope.empresa_activa.id
    }

    case ConsultaEndpoints.crear_o_actualizar(socket.assigns.consulta_sql, attrs) do
      {:ok, _endpoint} ->
        {:noreply,
         socket
         |> assign(:endpoint_error, nil)
         |> cargar()
         |> put_flash(:info, "Endpoint creado en borrador.")}

      {:error, changeset} ->
        {:noreply, assign(socket, :endpoint_error, errores_texto(changeset))}
    end
  end

  def manejar("publicar_endpoint", _params, socket) do
    {:ok, _} = ConsultaEndpoints.publicar(socket.assigns.endpoint)
    {:noreply, socket |> cargar() |> put_flash(:info, "Endpoint publicado.")}
  end

  def manejar("despublicar_endpoint", _params, socket) do
    {:ok, _} = ConsultaEndpoints.despublicar(socket.assigns.endpoint)
    {:noreply, socket |> cargar() |> put_flash(:info, "Endpoint en borrador: deja de responder.")}
  end

  def manejar("eliminar_endpoint", _params, socket) do
    :ok = ConsultaEndpoints.eliminar(socket.assigns.endpoint)

    {:noreply,
     socket
     |> assign(:key_temporal, nil)
     |> cargar()
     |> put_flash(:info, "Endpoint eliminado con sus credenciales.")}
  end

  def manejar("crear_credencial", %{"credencial" => params}, socket) do
    attrs = %{"nombre" => params["nombre"], "campos_permitidos" => Map.get(params, "campos", [])}

    case ConsultaEndpoints.crear_credencial(
           socket.assigns.endpoint,
           socket.assigns.consulta_sql,
           attrs
         ) do
      {:ok, _credencial, key} ->
        {:noreply,
         socket |> assign(:key_temporal, key) |> assign(:endpoint_error, nil) |> cargar()}

      {:error, changeset} ->
        {:noreply, assign(socket, :endpoint_error, errores_texto(changeset))}
    end
  end

  def manejar("regenerar_credencial", %{"id" => id}, socket) do
    {:ok, _credencial, key} =
      ConsultaEndpoints.regenerar_api_key_credencial(credencial(socket, id))

    {:noreply, socket |> assign(:key_temporal, key) |> cargar()}
  end

  def manejar("revocar_credencial", %{"id" => id}, socket) do
    {:ok, _} = ConsultaEndpoints.revocar_credencial(credencial(socket, id))
    {:noreply, cargar(socket)}
  end

  def manejar("ocultar_key", _params, socket), do: {:noreply, assign(socket, :key_temporal, nil)}

  defp credencial(socket, id),
    do: Enum.find(socket.assigns.credenciales, &(&1.id == String.to_integer(id)))

  defp errores_texto(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {mensaje, opciones} ->
      Enum.reduce(opciones, mensaje, fn {llave, valor}, acc ->
        String.replace(acc, "%{#{llave}}", to_string(valor))
      end)
    end)
    |> Enum.map_join("; ", fn {campo, mensajes} -> "#{campo}: #{Enum.join(mensajes, ", ")}" end)
  end

  # --- Panel ------------------------------------------------------------------

  attr :header, :map, required: true
  attr :consulta_sql, :map, required: true
  attr :endpoint, :map, default: nil
  attr :credenciales, :list, default: []
  attr :key_temporal, :string, default: nil
  attr :bpb_habilitado, :boolean, default: false
  attr :endpoint_error, :string, default: nil

  @doc """
  R53: el contrato de un Servicio es su llamada desde una regla, sus
  parámetros, sus columnas y, si tiene, su Endpoint (GET y POST, R50) con
  sus credenciales.
  """
  def panel(assigns) do
    parametros = assigns.consulta_sql.parametros

    ejemplo_valores =
      Enum.map_join(parametros, ", ", &"\"#{&1["nombre"]}\" => #{ejemplo_valor(&1["tipo"])}")

    ejemplo_json =
      Enum.map_join(parametros, ", ", &"\"#{&1["nombre"]}\": #{ejemplo_json(&1["tipo"])}")

    assigns =
      assigns
      |> assign(
        :ejemplo_regla,
        ~s|MetaBcApi.ejecutar_servicio("#{assigns.header.schema_context_name}", %{#{ejemplo_valores}})|
      )
      |> assign(:ejemplo_body, "{#{ejemplo_json}}")

    ~H"""
    <div class="flex flex-col gap-4">
      <div class="bg-white border border-gray-200 rounded-2xl shadow-sm p-4">
        <div class="text-[11px] font-bold uppercase tracking-wide text-gray-400 mb-2">
          Desde una regla de BC
        </div>
        <div
          id="contrato-regla"
          class="bg-gray-900 text-gray-100 rounded-lg px-3 py-2 overflow-x-auto font-mono text-xs"
        >
          {@ejemplo_regla}
        </div>
        <p class="text-gray-500 mt-2">
          Regresa
          <code class="font-mono">
            {"{:ok, %{columnas: [...], filas: [%{\"columna\" => valor}]}}"}
          </code>
          o <code class="font-mono">{"{:error, motivo}"}</code>. Corre como sistema (sin acotar), dentro de la transacción de la regla:
          ve lo que la regla ya cambió y un error no la aborta.
        </p>
      </div>

      <div class="bg-white border border-gray-200 rounded-2xl shadow-sm p-4">
        <div class="text-[11px] font-bold uppercase tracking-wide text-gray-400 mb-2">Parámetros</div>
        <p :if={@consulta_sql.parametros == []} class="text-gray-400">Sin parámetros.</p>
        <table
          :if={@consulta_sql.parametros != []}
          id="contrato-parametros"
          class="min-w-full text-xs"
        >
          <thead class="bg-gray-50">
            <tr>
              <th class="px-2 py-1.5 text-left font-semibold text-gray-500">Nombre</th>
              <th class="px-2 py-1.5 text-left font-semibold text-gray-500">Tipo</th>
              <th class="px-2 py-1.5 text-left font-semibold text-gray-500">Obligatorio</th>
              <th class="px-2 py-1.5 text-left font-semibold text-gray-500">Default</th>
            </tr>
          </thead>
          <tbody class="divide-y divide-gray-100">
            <tr :for={p <- @consulta_sql.parametros}>
              <td class="px-2 py-1.5 font-mono text-gray-800">{p["nombre"]}</td>
              <td class="px-2 py-1.5 text-gray-600">{etiqueta_tipo(p["tipo"])}</td>
              <td class="px-2 py-1.5 text-gray-600">{if p["obligatorio"], do: "Sí", else: "No"}</td>
              <td class="px-2 py-1.5 font-mono text-gray-600">{default_a_texto(p["default"])}</td>
            </tr>
          </tbody>
        </table>
      </div>

      <div class="bg-white border border-gray-200 rounded-2xl shadow-sm p-4">
        <div class="text-[11px] font-bold uppercase tracking-wide text-gray-400 mb-2">
          Columnas de salida
        </div>
        <p :if={@consulta_sql.columnas == []} class="text-gray-400">Todavía no hay SQL guardado.</p>
        <div class="flex flex-wrap gap-1.5">
          <span :for={c <- @consulta_sql.columnas} class="font-mono bg-gray-100 rounded px-1.5 py-0.5">
            {c["nombre"]} <span class="text-gray-400">{c["tipo"]}</span>
          </span>
        </div>
        <p class="text-gray-500 mt-2">
          Tope: {@consulta_sql.tope_renglones} renglones por llamada; si el resultado lo pasa, la llamada se rechaza.
        </p>
      </div>

      <div id="contrato-endpoint" class="bg-white border border-gray-200 rounded-2xl shadow-sm p-4">
        <div class="text-[11px] font-bold uppercase tracking-wide text-gray-400 mb-2">Por API</div>
        <%= if @endpoint do %>
          <div class="flex items-center gap-2 mb-2">
            <span class="text-[10px] font-bold px-1.5 py-0.5 rounded bg-emerald-100 text-emerald-700">
              GET
            </span>
            <span class="text-[10px] font-bold px-1.5 py-0.5 rounded bg-blue-100 text-blue-700">
              POST
            </span>
            <code id="contrato-ruta-endpoint" class="font-mono text-xs bg-gray-100 px-2 py-1 rounded">
              /api/consultas/{@endpoint.ruta}
            </code>
            <span class={[
              "text-[10px] font-bold px-1.5 py-0.5 rounded",
              @endpoint.estado == "publicado" && "bg-emerald-100 text-emerald-700",
              @endpoint.estado != "publicado" && "bg-gray-100 text-gray-500"
            ]}>
              {if @endpoint.estado == "publicado", do: "PUBLICADO", else: "BORRADOR"}
            </span>
          </div>
          <p
            :if={@endpoint.estado != "publicado"}
            id="aviso-borrador"
            class="mb-2 bg-amber-50 text-amber-700 rounded-lg px-2.5 py-1.5"
          >
            En borrador no responde: quien lo llame recibe 404. {if @bpb_habilitado,
              do: "Presiona Publicar para activarlo.",
              else: "Se publica desde local."}
          </p>
          <div class="bg-gray-900 text-gray-100 rounded-lg px-3 py-2 overflow-x-auto font-mono text-xs mb-2">
            POST /api/consultas/{@endpoint.ruta} · Authorization: Bearer &lt;api_key&gt; · {@ejemplo_body}
          </div>
          <p class="text-gray-500">
            Respuesta <code class="font-mono">{"{\"data\": [...], \"meta_campos\": [...]}"}</code>, sin paginar, con los campos que permite la credencial y acotada a la empresa del Endpoint.
            Errores: 400 parámetro faltante o inválido · 401 llave · 422 pasa el tope · 504 tiempo excedido.
          </p>

          <div :if={@bpb_habilitado} class="flex gap-2 mt-3">
            <button
              :if={@endpoint.estado != "publicado"}
              type="button"
              id="publicar-endpoint"
              phx-click="publicar_endpoint"
              class="px-3 py-1.5 rounded-lg bg-emerald-600 text-white font-semibold hover:bg-emerald-700 transition-colors"
            >
              Publicar
            </button>
            <button
              :if={@endpoint.estado == "publicado"}
              type="button"
              id="despublicar-endpoint"
              phx-click="despublicar_endpoint"
              class="px-3 py-1.5 rounded-lg border border-gray-300 text-gray-700 font-semibold hover:bg-gray-50 transition-colors"
            >
              Pasar a borrador
            </button>
            <button
              type="button"
              id="eliminar-endpoint"
              phx-click="eliminar_endpoint"
              data-confirm={"Se borra el endpoint '#{@endpoint.nombre}' y todas sus credenciales. El Servicio sigue. ¿Eliminar?"}
              class="px-3 py-1.5 rounded-lg text-red-600 font-semibold hover:bg-red-50 transition-colors"
            >
              Eliminar endpoint
            </button>
          </div>

          <div id="credenciales-servicio" class="mt-4 border-t border-gray-100 pt-3">
            <div class="font-semibold text-gray-700 mb-1.5">Credenciales</div>
            <div
              :if={@key_temporal}
              id="key-temporal"
              class="mb-2 bg-amber-50 border border-amber-200 rounded-lg px-3 py-2"
            >
              <p class="text-amber-800 font-semibold">
                Copia la llave ahora: no se vuelve a mostrar.
              </p>
              <code class="block font-mono text-xs break-all my-1">{@key_temporal}</code>
              <button
                type="button"
                id="ocultar-key"
                phx-click="ocultar_key"
                class="text-amber-800 hover:underline font-semibold"
              >
                Ya la copié
              </button>
            </div>
            <p :if={@credenciales == []} class="text-gray-400 mb-2">Sin credenciales.</p>
            <table :if={@credenciales != []} id="tabla-credenciales" class="min-w-full text-xs mb-2">
              <tbody class="divide-y divide-gray-100">
                <tr :for={c <- @credenciales} id={"credencial-#{c.id}"}>
                  <td class="py-1.5 pr-3 font-semibold text-gray-800">{c.nombre}</td>
                  <td class="py-1.5 pr-3 font-mono text-gray-400">…{c.api_key_sufijo}</td>
                  <td class="py-1.5 pr-3 font-mono text-gray-500">
                    {Enum.join(c.campos_permitidos, ", ")}
                  </td>
                  <td class="py-1.5 pr-3">
                    <span class={[
                      "text-[10px] font-bold px-1.5 py-0.5 rounded",
                      c.estado == "activa" && "bg-emerald-100 text-emerald-700",
                      c.estado != "activa" && "bg-gray-100 text-gray-500"
                    ]}>
                      {String.upcase(c.estado)}
                    </span>
                  </td>
                  <td class="py-1.5 text-right whitespace-nowrap">
                    <button
                      :if={c.estado == "activa"}
                      type="button"
                      phx-click="regenerar_credencial"
                      phx-value-id={c.id}
                      id={"regenerar-#{c.id}"}
                      data-confirm="La llave actual deja de funcionar de inmediato. ¿Regenerar?"
                      class="text-purple-700 hover:text-purple-900 font-semibold mr-3"
                    >
                      Regenerar llave
                    </button>
                    <button
                      :if={c.estado == "activa"}
                      type="button"
                      phx-click="revocar_credencial"
                      phx-value-id={c.id}
                      id={"revocar-#{c.id}"}
                      class="text-red-600 hover:text-red-800 font-semibold"
                    >
                      Revocar
                    </button>
                  </td>
                </tr>
              </tbody>
            </table>
            <form
              id="form-credencial"
              phx-submit="crear_credencial"
              class="flex flex-wrap items-end gap-2"
            >
              <label class="flex flex-col gap-0.5">
                <span class="text-gray-500">Nombre</span>
                <input
                  type="text"
                  name="credencial[nombre]"
                  required
                  placeholder="App vendedores"
                  autocomplete="off"
                  class="w-44 border border-gray-300 rounded-lg px-2 py-1 focus:border-purple-400 focus:ring-2 focus:ring-purple-100 transition-colors"
                />
              </label>
              <div class="flex flex-col gap-0.5">
                <span class="text-gray-500">Columnas que recibe</span>
                <div class="flex flex-wrap gap-2">
                  <label :for={c <- @consulta_sql.columnas} class="flex items-center gap-1 font-mono">
                    <input
                      type="checkbox"
                      name="credencial[campos][]"
                      value={c["nombre"]}
                      checked
                      class="accent-purple-600"
                    />{c["nombre"]}
                  </label>
                </div>
              </div>
              <button
                type="submit"
                id="crear-credencial"
                class="px-3 py-1.5 rounded-lg bg-purple-600 text-white font-semibold hover:bg-purple-700 transition-colors"
              >
                + Credencial
              </button>
            </form>
          </div>
        <% else %>
          <p class="text-gray-500 mb-2">
            Sin Endpoint todavía. Responde por GET y POST en <code class="font-mono">/api/consultas/&lt;ruta&gt;</code>, con credenciales propias.
          </p>
          <form
            :if={@bpb_habilitado and @consulta_sql.sql}
            id="form-endpoint"
            phx-submit="crear_endpoint"
            class="flex flex-wrap items-end gap-2"
          >
            <label class="flex flex-col gap-0.5">
              <span class="text-gray-500">Nombre</span>
              <input
                type="text"
                name="endpoint[nombre]"
                required
                value={@header.schema_context_label}
                autocomplete="off"
                class="w-48 border border-gray-300 rounded-lg px-2 py-1 focus:border-purple-400 focus:ring-2 focus:ring-purple-100 transition-colors"
              />
            </label>
            <label class="flex flex-col gap-0.5">
              <span class="text-gray-500">Ruta</span>
              <input
                type="text"
                name="endpoint[ruta]"
                required
                placeholder="precio-venta"
                autocomplete="off"
                class="w-48 font-mono border border-gray-300 rounded-lg px-2 py-1 focus:border-purple-400 focus:ring-2 focus:ring-purple-100 transition-colors"
              />
            </label>
            <button
              type="submit"
              id="crear-endpoint"
              class="px-3 py-1.5 rounded-lg bg-purple-600 text-white font-semibold hover:bg-purple-700 transition-colors"
            >
              Crear endpoint
            </button>
          </form>
          <p :if={!@bpb_habilitado} class="text-gray-400">
            El Endpoint se crea en local y llega aquí al publicar.
          </p>
          <p :if={@bpb_habilitado and !@consulta_sql.sql} class="text-gray-400">
            Guarda primero el SQL del Servicio.
          </p>
        <% end %>
        <p
          :if={@endpoint_error}
          id="endpoint-error"
          class="mt-2 bg-red-50 text-red-700 rounded-lg px-2.5 py-1.5"
        >
          {@endpoint_error}
        </p>
      </div>
    </div>
    """
  end

  defp ejemplo_valor("lista_enteros"), do: "[101, 102]"
  defp ejemplo_valor("lista_decimales"), do: "[Decimal.new(\"1.5\"), Decimal.new(\"2\")]"
  defp ejemplo_valor("fecha"), do: "~D[2026-10-01]"
  defp ejemplo_valor("texto"), do: "\"texto\""
  defp ejemplo_valor("decimal"), do: "Decimal.new(\"1.5\")"
  defp ejemplo_valor("booleano"), do: "true"
  defp ejemplo_valor(_tipo), do: "1"

  defp ejemplo_json("lista_enteros"), do: "[101, 102]"
  defp ejemplo_json("lista_decimales"), do: "[1.5, 2]"
  defp ejemplo_json("fecha"), do: "\"2026-10-01\""
  defp ejemplo_json("texto"), do: "\"texto\""
  defp ejemplo_json("decimal"), do: "1.5"
  defp ejemplo_json("booleano"), do: "true"
  defp ejemplo_json(_tipo), do: "1"
end
