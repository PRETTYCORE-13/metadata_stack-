defmodule MetadataAppWeb.Sysadmin.ServiciosLive do
  # Sección "Servicios" (SPEC-SYS-2509202601 §11.6, R53.1-R53.2): contrato,
  # Endpoint y credenciales de cada Consulta SQL de uso "servicio", en
  # cualquier ambiente. El SQL y los parámetros se editan solo en local,
  # en ConsultaSqlEditorLive; acá, fuera de local, solo se consultan y se
  # manejan las credenciales.
  #
  #   :index -- lista los Servicios con su Endpoint (ConsultasSql.listar_servicios/0).
  #   :ver   -- el panel de ServicioEndpoint, ruteado por el nombre del BC.
  use MetadataAppWeb, :live_view_admin

  on_mount {MetadataAppWeb.UsuarioAuth, :mount_current_scope}
  on_mount {MetadataAppWeb.Hooks.Autorizacion, {"sysadmin_endpoints", "leer"}}

  alias MetadataApp.ConsultasSql
  alias MetadataApp.BusinessProcessBuilder.MetaSchemaContext
  alias MetadataAppWeb.AdminNav
  alias MetadataAppWeb.Sysadmin.ServicioEndpoint

  @eventos_servicio_endpoint ServicioEndpoint.eventos()

  @menu [
    %{tipo: :pagina, id: "bc_list", label: "BC List", nav: "/sysadmin/bc-list"},
    %{tipo: :pagina, id: "buscar_trn", label: "Buscar TRN", nav: "/sysadmin/buscar-trn"},
    %{tipo: :pagina, id: "roles", label: "Roles y Usuarios", nav: "/sysadmin/roles"},
    %{tipo: :pagina, id: "usuarios_empresa", label: "Usuarios", nav: "/sysadmin/usuarios"},
    %{tipo: :pagina, id: "empresas", label: "Empresas", nav: "/sysadmin/empresas"},
    %{tipo: :pagina, id: "credenciales", label: "Credenciales", nav: "/sysadmin/credenciales"},
    %{tipo: :pagina, id: "ambientes", label: "Ambientes de Deploy", nav: "/sysadmin/ambientes"},
    %{
      tipo: :pagina,
      id: "acciones_externas",
      label: "Acciones externas",
      nav: "/sysadmin/acciones-externas"
    },
    %{
      tipo: :pagina,
      id: "jerarquia",
      label: "Jerarquía organizacional",
      nav: "/sysadmin/jerarquia"
    },
    %{tipo: :pagina, id: "panel_control", label: "Panel Control", nav: "/sysadmin/panel-control"},
    %{
      tipo: :pagina,
      id: "sesiones_movil",
      label: "Sesiones móviles",
      nav: "/sysadmin/sesiones-movil"
    },
    %{tipo: :pagina, id: "endpoints", label: "Endpoints", nav: "/sysadmin/endpoints"},
    %{tipo: :pagina, id: "servicios", label: "Servicios", nav: "/sysadmin/servicios"},
    %{tipo: :pagina, id: "propagacion", label: "Propagación", nav: "/sysadmin/propagacion"}
  ]

  def mount(params, _session, socket) do
    socket =
      socket
      |> assign(:current_page, "servicios")
      |> assign(:menu_items, AdminNav.filtrar_menu(@menu))
      |> assign(:sidebar_open, false)
      |> assign(:show_programacion_children, false)
      |> assign(:show_clientes_children, false)
      |> assign(:show_prettycore_children, false)
      |> assign(:bpb_habilitado, Application.get_env(:metadata_app, :bpb_habilitado, false))

    {:ok, cargar(socket, socket.assigns.live_action, params)}
  end

  defp cargar(socket, :index, _params),
    do: assign(socket, :servicios, ConsultasSql.listar_servicios())

  defp cargar(socket, :ver, %{"nombre" => nombre}) do
    with %{schema_context_type: 4} = header <- MetaSchemaContext.obtener_header_por_nombre(nombre),
         %{uso: "servicio"} = consulta_sql <- ConsultasSql.obtener_por_header_id(header.id) do
      socket
      |> assign(:header, header)
      |> assign(:consulta_sql, consulta_sql)
      |> ServicioEndpoint.cargar()
    else
      _otro ->
        socket
        |> put_flash(:error, "Ese servicio no existe.")
        |> push_navigate(to: ~p"/sysadmin/servicios")
    end
  end

  def handle_event(evento, params, socket) when evento in @eventos_servicio_endpoint,
    do: ServicioEndpoint.manejar(evento, params, socket)

  def render(assigns) do
    ~H"""
    <div class="max-w-7xl mx-auto p-6 text-xs font-sans">
      <.vista_index :if={@live_action == :index} servicios={@servicios} />
      <.vista_ver
        :if={@live_action == :ver and assigns[:consulta_sql] != nil}
        header={@header}
        consulta_sql={@consulta_sql}
        endpoint={@endpoint}
        credenciales={@credenciales}
        key_temporal={@key_temporal}
        bpb_habilitado={@bpb_habilitado}
        endpoint_error={@endpoint_error}
      />
    </div>
    """
  end

  attr :servicios, :list, required: true

  defp vista_index(assigns) do
    ~H"""
    <div class="mb-4">
      <h1 class="text-lg font-bold text-gray-900 flex items-center gap-2">
        <span class="material-symbols-outlined text-teal-600">hub</span> Servicios
      </h1>
      <p class="text-gray-500 mt-1">
        Consultas SQL con parámetros que se llaman desde una regla o por API. Aquí se ve su contrato y se manejan las credenciales de su Endpoint.
      </p>
    </div>

    <div class="bg-white border border-gray-200 rounded-2xl shadow-sm overflow-x-auto">
      <table id="tabla-servicios" class="min-w-full divide-y divide-gray-200 text-xs">
        <thead class="bg-gray-50">
          <tr>
            <th class="px-3 py-2 text-left font-semibold text-gray-500 uppercase tracking-wide">
              Servicio
            </th>
            <th class="px-3 py-2 text-left font-semibold text-gray-500 uppercase tracking-wide">
              Parámetros
            </th>
            <th class="px-3 py-2 text-left font-semibold text-gray-500 uppercase tracking-wide">
              Endpoint
            </th>
            <th class="px-3 py-2"></th>
          </tr>
        </thead>
        <tbody class="divide-y divide-gray-100">
          <tr
            :for={s <- @servicios}
            id={"servicio-#{s.nombre}"}
            class="hover:bg-gray-50 transition-colors"
          >
            <td class="px-3 py-2.5">
              <div class="font-semibold text-gray-800">{s.etiqueta}</div>
              <div class="font-mono text-gray-400">{s.nombre}</div>
            </td>
            <td class="px-3 py-2.5 font-mono text-gray-500">
              {Enum.map_join(s.parametros, ", ", & &1["nombre"])}
            </td>
            <td class="px-3 py-2.5">
              <span :if={is_nil(s.endpoint_ruta)} class="text-gray-400">Sin Endpoint</span>
              <span :if={s.endpoint_ruta} class="font-mono text-gray-600 mr-2">
                /api/consultas/{s.endpoint_ruta}
              </span>
              <span
                :if={s.endpoint_ruta}
                class={[
                  "text-[10px] font-bold px-1.5 py-0.5 rounded",
                  s.endpoint_estado == "publicado" && "bg-emerald-100 text-emerald-700",
                  s.endpoint_estado != "publicado" && "bg-gray-100 text-gray-500"
                ]}
              >
                {if s.endpoint_estado == "publicado", do: "PUBLICADO", else: "BORRADOR"}
              </span>
            </td>
            <td class="px-3 py-2.5 text-right">
              <.link
                navigate={~p"/sysadmin/servicios/#{s.nombre}"}
                id={"abrir-servicio-#{s.nombre}"}
                class="text-blue-600 hover:text-blue-800 font-semibold"
              >
                Abrir
              </.link>
            </td>
          </tr>
          <tr :if={@servicios == []}>
            <td colspan="4" class="px-3 py-8 text-center text-gray-400">Todavía no hay Servicios.</td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  defp vista_ver(assigns) do
    ~H"""
    <div class="flex items-center justify-between mb-4">
      <div>
        <.link
          navigate={~p"/sysadmin/servicios"}
          class="text-gray-500 hover:text-gray-800 transition-colors"
        >
          ← Servicios
        </.link>
        <h1 class="text-lg font-bold text-gray-900 flex items-center gap-2 mt-1">
          <span class="material-symbols-outlined text-teal-600">hub</span>
          {@header.schema_context_label}
          <span class="font-mono text-xs font-normal text-gray-400">
            {@header.schema_context_name}
          </span>
        </h1>
      </div>
      <.link
        :if={@bpb_habilitado}
        id="editar-sql-servicio"
        navigate={"/sysadmin/bc-list/#{@header.schema_context_name}/consulta-sql"}
        class="px-3 py-1.5 rounded-lg border border-gray-300 text-gray-700 font-semibold hover:bg-gray-50 transition-colors"
      >
        Editar SQL
      </.link>
    </div>

    <ServicioEndpoint.panel
      header={@header}
      consulta_sql={@consulta_sql}
      endpoint={@endpoint}
      credenciales={@credenciales}
      key_temporal={@key_temporal}
      bpb_habilitado={@bpb_habilitado}
      endpoint_error={@endpoint_error}
    />
    """
  end
end
