defmodule MetadataAppWeb.Sysadmin.ConsultaSqlEditorLive do
  # Admin de una Consulta SQL / SQL View (schema_context_type: 4,
  # SPEC-SYS-2509202601) — mismo espíritu que ConsultaEditorLive, con 3
  # tabs (R23):
  #   - Configuración: encabezado + uso (Diccionario/Consulta), el SQL con
  #     "Validar y guardar", columnas detectadas, vista previa de 5 filas,
  #     aviso de alcance y, si es Diccionario, "BC que pueden usarla".
  #   - Contrato: solo el GET de lectura.
  #   - Permisos: embebe CatalogoPermisosLive, que trata el tipo 4 como
  #     solo lectura (~w(leer)).
  # La lógica vive en MetadataApp.ConsultasSql; acá solo pantalla.
  use MetadataAppWeb, :live_view_admin

  on_mount {MetadataAppWeb.UsuarioAuth, :mount_current_scope}
  on_mount {MetadataAppWeb.Hooks.Autorizacion, {"sysadmin_bc", "editar"}}

  alias MetadataApp.ConsultasSql
  alias MetadataApp.BusinessProcessBuilder.MetaSchemaContext
  alias MetadataAppWeb.AdminNav
  alias MetadataAppWeb.Sysadmin.ServicioEndpoint
  alias MetadataAppWeb.EncabezadoBcComponents

  import MetadataAppWeb.EncabezadoBcComponents, only: [panel_encabezado: 1]
  import MetadataAppWeb.Sysadmin.ServicioEndpoint, only: [etiqueta_tipo: 1, default_a_texto: 1]

  @eventos_servicio_endpoint ServicioEndpoint.eventos()

  @menu [
    %{tipo: :pagina, id: "bc_list", label: "BC List", nav: "/sysadmin/bc-list"},
    %{tipo: :pagina, id: "buscar_trn", label: "Buscar TRN", nav: "/sysadmin/buscar-trn"},
    %{tipo: :pagina, id: "roles", label: "Roles y Usuarios", nav: "/sysadmin/roles"},
    %{tipo: :pagina, id: "usuarios_empresa", label: "Usuarios", nav: "/sysadmin/usuarios"},
    %{tipo: :pagina, id: "empresas", label: "Empresas", nav: "/sysadmin/empresas"},
    %{tipo: :pagina, id: "credenciales", label: "Credenciales", nav: "/sysadmin/credenciales"},
    %{tipo: :pagina, id: "ambientes", label: "Ambientes de Deploy", nav: "/sysadmin/ambientes"},
    %{tipo: :pagina, id: "acciones_externas", label: "Acciones externas", nav: "/sysadmin/acciones-externas"},
    %{tipo: :pagina, id: "jerarquia", label: "Jerarquía organizacional", nav: "/sysadmin/jerarquia"},
    %{tipo: :pagina, id: "panel_control", label: "Panel Control", nav: "/sysadmin/panel-control"},
    %{tipo: :pagina, id: "sesiones_movil", label: "Sesiones móviles", nav: "/sysadmin/sesiones-movil"},
    %{tipo: :pagina, id: "endpoints", label: "Endpoints", nav: "/sysadmin/endpoints"},
    %{tipo: :pagina, id: "propagacion", label: "Propagación", nav: "/sysadmin/propagacion"}
  ]

  @tabs [
    {"configuracion", "Configuración"},
    {"contrato", "Contrato"},
    {"permisos", "Permisos"}
  ]

  def mount(%{"nombre" => nombre} = params, _session, socket) do
    socket =
      socket
      |> assign(:current_page, "bc_list")
      |> assign(:menu_items, AdminNav.filtrar_menu(@menu))
      |> assign(:sidebar_open, false)
      |> assign(:show_programacion_children, false)
      |> assign(:show_clientes_children, false)
      |> assign(:show_prettycore_children, false)
      |> assign(:tabs, @tabs)
      |> assign(:tab, if(Enum.any?(@tabs, &(elem(&1, 0) == params["tab"])), do: params["tab"], else: "configuracion"))

    case MetaSchemaContext.obtener_header_por_nombre(nombre) do
      %{schema_context_type: 4} = header ->
        {:ok, socket |> assign(:header, header) |> cargar()}

      _otro ->
        {:ok,
         socket
         |> put_flash(:error, "Esa SQL View no existe.")
         |> push_navigate(to: ~p"/sysadmin/bc-list")}
    end
  end

  defp cargar(socket) do
    header = socket.assigns.header
    consulta_sql = ConsultasSql.obtener_por_header_id(header.id)

    socket
    |> assign(:header_form, EncabezadoBcComponents.form_desde_header(header))
    |> assign(:iconos_sugeridos, EncabezadoBcComponents.iconos_sugeridos())
    |> assign(:carpetas, MetaSchemaContext.listar_carpetas_existentes())
    |> assign(:consulta_sql, consulta_sql)
    |> assign(:sql_texto, consulta_sql.sql || "")
    |> assign(:sql_error, nil)
    |> assign(:vista_previa, vista_previa(consulta_sql, header))
    |> assign(:usos, ConsultasSql.campos_que_usan(header.schema_context_name))
    |> assign(:busqueda_bc, "")
    |> assign(:bc_error, nil)
    |> assign(:uso_error, nil)
    |> assign(:parametros_form, Enum.map(consulta_sql.parametros, &parametro_a_form/1))
    |> assign(:tope_texto, to_string(consulta_sql.tope_renglones))
    |> assign(:prueba_valores, %{})
    |> assign(:prueba_resultado, nil)
    |> assign(:bpb_habilitado, Application.get_env(:metadata_app, :bpb_habilitado, false))
    |> assign(:key_temporal, nil)
    |> assign(:endpoint_error, nil)
    |> ServicioEndpoint.cargar()
  end

  # Uso Servicio (SPEC-SYS-2509202601 §11.8): los parámetros se editan en
  # memoria como texto y se validan al "Validar y guardar"
  # (ConsultasSql.guardar_sql/3).
  defp parametro_a_form(p) do
    %{
      "nombre" => p["nombre"],
      "tipo" => p["tipo"],
      "obligatorio" => p["obligatorio"] == true,
      "default" => default_a_texto(p["default"])
    }
  end

  # `parametros[i][campo]` del formulario -> lista en el orden de `i`. El
  # checkbox de obligatorio manda "false" (input oculto) y "true" si se
  # marca; el último valor gana.
  defp parametros_de_form(nil), do: []

  defp parametros_de_form(por_indice) when is_map(por_indice) do
    por_indice
    |> Enum.sort_by(fn {indice, _} -> String.to_integer(indice) end)
    |> Enum.map(fn {_indice, p} ->
      %{
        "nombre" => String.trim(p["nombre"] || ""),
        "tipo" => p["tipo"] || "entero",
        "obligatorio" => p["obligatorio"] == "true",
        "default" => p["default"] || ""
      }
    end)
  end

  defp vista_previa(%{uso: "servicio"}, _header), do: nil
  defp vista_previa(%{sql: nil}, _header), do: nil

  defp vista_previa(_consulta_sql, header) do
    case ConsultasSql.vista_previa(header.schema_context_name) do
      {:ok, previa} -> previa
      {:error, motivo} -> %{error: ConsultasSql.mensaje_ejecucion(motivo)}
    end
  end

  def handle_event("change_page", %{"id" => id}, socket), do: AdminNav.handle_nav(id, socket, "bc_list")

  def handle_event("cambiar_tab", %{"tab" => tab}, socket), do: {:noreply, assign(socket, :tab, tab)}

  # --- Encabezado (mismo componente que BcMotorLive/ConsultaEditorLive) ---

  def handle_event("validar_header", %{"header" => params}, socket) do
    {:noreply, assign(socket, :header_form, EncabezadoBcComponents.validar(params, socket.assigns.header.id))}
  end

  def handle_event("elegir_icono_header", %{"icono" => icono}, socket) do
    {:noreply, update(socket, :header_form, &EncabezadoBcComponents.elegir_icono(&1, icono))}
  end

  # R4: un Diccionario en uso no puede volverse visible.
  def handle_event("guardar_header", %{"header" => params}, socket) do
    %{header: header, consulta_sql: consulta_sql} = socket.assigns

    with :ok <- ConsultasSql.validar_cambio(header.schema_context_name, consulta_sql.uso, params["visible"] == "true"),
         {:ok, header} <- EncabezadoBcComponents.guardar(params, header) do
      {:noreply,
       socket
       |> assign(:header, header)
       |> assign(:header_form, EncabezadoBcComponents.form_desde_header(header))
       |> put_flash(:info, "Encabezado actualizado.")}
    else
      {:error, mensaje} when is_binary(mensaje) -> {:noreply, put_flash(socket, :error, mensaje)}
      {:error, header_form} -> {:noreply, assign(socket, :header_form, header_form)}
    end
  end

  # --- Uso y SQL ------------------------------------------------------------

  def handle_event("cambiar_uso", %{"uso" => uso}, socket) do
    case ConsultasSql.cambiar_uso(socket.assigns.header.schema_context_name, uso) do
      {:ok, consulta_sql} ->
        {:noreply, socket |> assign(:consulta_sql, consulta_sql) |> assign(:uso_error, nil) |> put_flash(:info, "Uso actualizado.")}

      {:error, mensaje} ->
        {:noreply, assign(socket, :uso_error, mensaje)}
    end
  end

  def handle_event("editar_sql", %{"sql" => sql} = params, socket) do
    {:noreply, socket |> assign(:sql_texto, sql) |> recordar_servicio(params)}
  end

  def handle_event("guardar_sql", %{"sql" => sql} = params, socket) do
    header = socket.assigns.header
    socket = recordar_servicio(socket, params)
    servicio? = socket.assigns.consulta_sql.uso == "servicio"

    extras =
      if servicio?,
        do: %{"parametros" => socket.assigns.parametros_form, "tope_renglones" => socket.assigns.tope_texto},
        else: %{}

    case ConsultasSql.guardar_sql(header.schema_context_name, sql, extras) do
      {:ok, consulta_sql} ->
        {:noreply,
         socket
         |> assign(:consulta_sql, consulta_sql)
         |> assign(:sql_texto, consulta_sql.sql)
         |> assign(:sql_error, nil)
         |> assign(:parametros_form, Enum.map(consulta_sql.parametros, &parametro_a_form/1))
         |> assign(:tope_texto, to_string(consulta_sql.tope_renglones))
         |> assign(:prueba_resultado, nil)
         |> assign(:vista_previa, vista_previa(consulta_sql, header))
         |> put_flash(:info, if(servicio?, do: "SQL validado y función actualizada.", else: "SQL validado y vista actualizada."))}

      {:error, mensaje} ->
        {:noreply, socket |> assign(:sql_texto, sql) |> assign(:sql_error, mensaje)}
    end
  end

  # --- Parámetros y prueba de un Servicio (R52) -----------------------------

  def handle_event("agregar_parametro", _params, socket) do
    nuevo = %{"nombre" => "", "tipo" => "entero", "obligatorio" => true, "default" => ""}
    {:noreply, update(socket, :parametros_form, &(&1 ++ [nuevo]))}
  end

  def handle_event("quitar_parametro", %{"indice" => indice}, socket) do
    {:noreply, update(socket, :parametros_form, &List.delete_at(&1, String.to_integer(indice)))}
  end

  def handle_event("editar_prueba", %{"valores" => valores}, socket), do: {:noreply, assign(socket, :prueba_valores, valores)}

  def handle_event("probar_servicio", params, socket) do
    valores = Map.get(params, "valores", %{})

    resultado =
      case ConsultasSql.ejecutar_servicio(socket.assigns.header.schema_context_name, valores, socket.assigns.current_scope) do
        {:ok, resultado} -> resultado
        {:error, motivo} -> %{error: ConsultasSql.mensaje_ejecucion(motivo)}
      end

    {:noreply, socket |> assign(:prueba_valores, valores) |> assign(:prueba_resultado, resultado)}
  end

  # --- Endpoint del Servicio (§11.6): lo maneja ServicioEndpoint ----------

  def handle_event(evento, params, socket) when evento in @eventos_servicio_endpoint,
    do: ServicioEndpoint.manejar(evento, params, socket)

  # --- BC que pueden usarla (R14-R17) ---------------------------------------

  def handle_event("buscar_bc", %{"busqueda" => texto}, socket), do: {:noreply, assign(socket, :busqueda_bc, texto)}

  def handle_event("autorizar_bc", %{"bc" => bc}, socket) do
    ConsultasSql.autorizar_bc(socket.assigns.header.schema_context_name, bc)
    |> despues_de_autorizados(socket)
  end

  def handle_event("desautorizar_bc", %{"bc" => bc}, socket) do
    ConsultasSql.desautorizar_bc(socket.assigns.header.schema_context_name, bc)
    |> despues_de_autorizados(socket)
  end

  # Mismo formulario que el SQL: para un Servicio también trae la tabla de
  # parámetros y el tope, que se conservan mientras se edita.
  defp recordar_servicio(socket, params) do
    if socket.assigns.consulta_sql.uso == "servicio" do
      socket
      |> assign(:parametros_form, parametros_de_form(params["parametros"]))
      |> assign(:tope_texto, params["tope_renglones"] || socket.assigns.tope_texto)
    else
      socket
    end
  end

  defp despues_de_autorizados({:ok, consulta_sql}, socket),
    do: {:noreply, socket |> assign(:consulta_sql, consulta_sql) |> assign(:bc_error, nil) |> assign(:busqueda_bc, "")}

  defp despues_de_autorizados({:error, mensaje}, socket), do: {:noreply, assign(socket, :bc_error, mensaje)}

  defp candidatos_bc(busqueda, autorizados) do
    texto = busqueda |> String.trim() |> String.downcase()

    if texto == "" do
      []
    else
      MetaSchemaContext.listar_catalogos_referenciables()
      |> Enum.reject(&(String.ends_with?(&1.etiqueta, "(sistema)") or &1.nombre in autorizados))
      |> Enum.filter(&(String.contains?(String.downcase(&1.nombre), texto) or String.contains?(String.downcase(&1.etiqueta), texto)))
      |> Enum.take(10)
    end
  end

  # --- Render ---------------------------------------------------------------

  def render(assigns) do
    ~H"""
    <div class="max-w-7xl mx-auto p-6 text-xs font-sans">
      <div class="flex items-start justify-between gap-4 mb-4">
        <div class="flex items-start gap-2">
          <.link navigate={~p"/sysadmin/bc-list"} title="Volver al listado de BC"
            class="mt-0.5 w-7 h-7 flex items-center justify-center rounded-lg text-gray-500 hover:bg-gray-100 hover:text-gray-700 transition-colors shrink-0">
            <span class="material-symbols-outlined" style="font-size: 18px">arrow_back</span>
          </.link>
          <div>
            <h1 class="text-lg font-bold text-gray-900 flex items-center gap-2">
              <span class="material-symbols-outlined text-purple-600">database</span>
              {@header.schema_context_label}
            </h1>
            <p class="mt-0.5 text-gray-500">
              SQL View · {etiqueta_uso(@consulta_sql.uso)} ·
              <span class="font-mono">{@header.schema_context_name}</span> — {@header.schema_context_nav}
            </p>
          </div>
        </div>
        <.link :if={@header.schema_visible and @consulta_sql.sql} navigate={@header.schema_context_nav}
          class="shrink-0 font-semibold text-purple-700 hover:underline">
          Ver listado →
        </.link>
      </div>

      <div class="flex gap-1 border-b border-gray-200 mb-4">
        <button :for={{id, etiqueta} <- @tabs} type="button" phx-click="cambiar_tab" phx-value-tab={id} id={"tab-#{id}"}
          class={[
            "px-3 py-2 text-sm font-semibold border-b-2 -mb-px transition-colors",
            @tab == id && "border-purple-600 text-purple-700",
            @tab != id && "border-transparent text-gray-500 hover:text-gray-700"
          ]}>
          {etiqueta}
        </button>
      </div>

      <.panel_configuracion :if={@tab == "configuracion"} {assigns} />
      <.panel_contrato :if={@tab == "contrato" and @consulta_sql.uso != "servicio"} header={@header} consulta_sql={@consulta_sql} />
      <ServicioEndpoint.panel :if={@tab == "contrato" and @consulta_sql.uso == "servicio"} header={@header} consulta_sql={@consulta_sql}
        endpoint={@endpoint} credenciales={@credenciales} key_temporal={@key_temporal} bpb_habilitado={@bpb_habilitado}
        endpoint_error={@endpoint_error} />
      <div :if={@tab == "permisos"} id="consulta-sql-panel-permisos">
        {live_render(@socket, MetadataAppWeb.Sysadmin.CatalogoPermisosLive,
          id: "permisos-embebido-#{@header.schema_context_name}",
          session: %{"recurso" => @header.schema_context_name}
        )}
      </div>
    </div>
    """
  end

  defp panel_configuracion(assigns) do
    assigns =
      assigns
      |> assign(:alcance, ConsultasSql.columnas_de_alcance(assigns.consulta_sql.columnas))
      |> assign(:candidatos, candidatos_bc(assigns.busqueda_bc, assigns.consulta_sql.bcs_autorizados))

    ~H"""
    <div class="flex flex-col gap-4">
      <.panel_encabezado header_form={@header_form} iconos_sugeridos={@iconos_sugeridos} carpetas={@carpetas} />

      <div class="bg-white border border-gray-200 rounded-2xl shadow-sm p-4">
        <div class="text-[11px] font-bold uppercase tracking-wide text-gray-400 mb-2">Uso</div>
        <div :if={@consulta_sql.uso == "servicio"} id="uso-servicio-fijo" class="rounded-xl border border-teal-400 bg-teal-50 px-3 py-2">
          <span class="font-semibold text-gray-800">Servicio</span>
          <p class="text-gray-500 mt-0.5">
            Recibe parámetros en cada llamada. Lo llaman las reglas de un BC
            (<code class="font-mono">MetaBcApi.ejecutar_servicio/2</code>) o una API por su Endpoint.
            No aparece en el menú ni en combos, y su uso no se puede cambiar.
          </p>
        </div>
        <form :if={@consulta_sql.uso != "servicio"} id="form-uso" phx-change="cambiar_uso" class="flex flex-wrap gap-3">
          <label :for={{valor, titulo, ayuda} <- [{"diccionario", "Diccionario", "Lista para los combos de campos referencia. Necesita una columna id y una de descripción."}, {"consulta", "Consulta", "Reporte de solo lectura. Si es visible, aparece en el menú."}]}
            class={[
              "flex-1 min-w-[16rem] cursor-pointer rounded-xl border px-3 py-2 transition-colors",
              @consulta_sql.uso == valor && "border-purple-500 bg-purple-50",
              @consulta_sql.uso != valor && "border-gray-200 hover:border-purple-200"
            ]}>
            <input type="radio" name="uso" value={valor} checked={@consulta_sql.uso == valor} class="accent-purple-600 mr-1.5" id={"uso-#{valor}"} />
            <span class="font-semibold text-gray-800">{titulo}</span>
            <p class="text-gray-500 mt-0.5">{ayuda}</p>
          </label>
        </form>
        <p :if={@uso_error} id="uso-error" class="mt-2 bg-red-50 text-red-700 rounded-lg px-2.5 py-1.5">{@uso_error}</p>
      </div>

      <div class="bg-white border border-gray-200 rounded-2xl shadow-sm p-4">
        <div class="text-[11px] font-bold uppercase tracking-wide text-gray-400 mb-1">SQL</div>
        <p :if={@consulta_sql.uso != "servicio"} class="text-gray-500 mb-2">
          Una sola consulta de lectura (<code class="font-mono">SELECT</code> o <code class="font-mono">WITH … SELECT</code>), sin parámetros.
          Al guardar se valida contra la base y se convierte en la vista <code class="font-mono">{@header.schema_context_name}</code>.
        </p>
        <p :if={@consulta_sql.uso == "servicio"} class="text-gray-500 mb-2">
          Una sola consulta de lectura (<code class="font-mono">SELECT</code> o <code class="font-mono">WITH … SELECT</code>).
          Usa cada parámetro como <code class="font-mono">:nombre</code> (por ejemplo, <code class="font-mono">WHERE d.id = :direccion_id</code>;
          una lista de enteros se usa como <code class="font-mono">= ANY(:productos)</code>).
          Al guardar se valida contra la base y se convierte en la función <code class="font-mono">{@header.schema_context_name}</code>.
        </p>
        <form id="form-sql" phx-change="editar_sql" phx-submit="guardar_sql">
          <div :if={@consulta_sql.uso == "servicio"} id="parametros-servicio" class="mb-3">
            <div class="flex items-center justify-between mb-1.5">
              <span class="font-semibold text-gray-700">Parámetros</span>
              <button type="button" id="agregar-parametro" phx-click="agregar_parametro"
                class="text-purple-700 hover:text-purple-900 font-semibold">+ Agregar parámetro</button>
            </div>
            <p :if={@parametros_form == []} class="text-gray-400 mb-1">Sin parámetros todavía.</p>
            <table :if={@parametros_form != []} id="tabla-parametros" class="min-w-full text-xs">
              <thead class="bg-gray-50">
                <tr>
                  <th class="px-2 py-1.5 text-left font-semibold text-gray-500">Nombre</th>
                  <th class="px-2 py-1.5 text-left font-semibold text-gray-500">Tipo</th>
                  <th class="px-2 py-1.5 text-center font-semibold text-gray-500">Obligatorio</th>
                  <th class="px-2 py-1.5 text-left font-semibold text-gray-500">Default</th>
                  <th class="px-2 py-1.5"></th>
                </tr>
              </thead>
              <tbody class="divide-y divide-gray-100">
                <tr :for={{p, i} <- Enum.with_index(@parametros_form)} id={"parametro-#{i}"}>
                  <td class="px-2 py-1">
                    <input type="text" name={"parametros[#{i}][nombre]"} value={p["nombre"]} placeholder="direccion_id" autocomplete="off"
                      class="w-full font-mono border border-gray-300 rounded-lg px-2 py-1 focus:border-purple-400 focus:ring-2 focus:ring-purple-100 transition-colors" />
                  </td>
                  <td class="px-2 py-1">
                    <select name={"parametros[#{i}][tipo]"}
                      class="w-full border border-gray-300 rounded-lg px-2 py-1 focus:border-purple-400 focus:ring-2 focus:ring-purple-100 transition-colors">
                      <option :for={{valor, etiqueta} <- tipos_parametro()} value={valor} selected={p["tipo"] == valor}>{etiqueta}</option>
                    </select>
                  </td>
                  <td class="px-2 py-1 text-center">
                    <input type="hidden" name={"parametros[#{i}][obligatorio]"} value="false" />
                    <input type="checkbox" name={"parametros[#{i}][obligatorio]"} value="true" checked={p["obligatorio"]} class="accent-purple-600" />
                  </td>
                  <td class="px-2 py-1">
                    <input type="text" name={"parametros[#{i}][default]"} value={p["default"]} placeholder="(vacío)" autocomplete="off"
                      class="w-full border border-gray-300 rounded-lg px-2 py-1 focus:border-purple-400 focus:ring-2 focus:ring-purple-100 transition-colors" />
                  </td>
                  <td class="px-2 py-1 text-right">
                    <button type="button" phx-click="quitar_parametro" phx-value-indice={i} id={"quitar-parametro-#{i}"}
                      class="text-red-600 hover:text-red-800 font-semibold">Quitar</button>
                  </td>
                </tr>
              </tbody>
            </table>
            <label class="mt-2 flex items-center gap-2 text-gray-600">
              Tope de renglones por llamada
              <input type="number" name="tope_renglones" id="tope-renglones" value={@tope_texto} min="1" max="5000"
                class="w-24 border border-gray-300 rounded-lg px-2 py-1 focus:border-purple-400 focus:ring-2 focus:ring-purple-100 transition-colors" />
              <span class="text-gray-400">Si el resultado lo pasa, la llamada se rechaza completa.</span>
            </label>
          </div>
          <textarea name="sql" id="sql-editor" rows="12" spellcheck="false" phx-debounce="300"
            placeholder="SELECT e.id, e.nombre AS descripcion, e.branch_id FROM pty_ch_empleados e WHERE …"
            class="w-full font-mono text-[12px] leading-relaxed border border-gray-300 rounded-xl px-3 py-2 bg-gray-50 focus:bg-white focus:border-purple-400 focus:ring-2 focus:ring-purple-100 transition-colors">{@sql_texto}</textarea>
          <div :if={@sql_error} id="sql-error" class="mt-2 bg-red-50 text-red-700 rounded-lg px-2.5 py-1.5 whitespace-pre-wrap">{@sql_error}</div>
          <div class="flex justify-end mt-2">
            <button type="submit" id="guardar-sql" phx-disable-with="Validando…"
              class="px-4 py-1.5 rounded-lg bg-purple-600 text-white font-semibold hover:bg-purple-700 transition-colors">
              Validar y guardar
            </button>
          </div>
        </form>
      </div>

      <div :if={@consulta_sql.sql} class="grid gap-4 md:grid-cols-[18rem_1fr]">
        <div class="bg-white border border-gray-200 rounded-2xl shadow-sm p-4">
          <div class="text-[11px] font-bold uppercase tracking-wide text-gray-400 mb-2">Columnas detectadas</div>
          <table id="columnas-detectadas" class="min-w-full text-xs">
            <tbody class="divide-y divide-gray-100">
              <tr :for={c <- @consulta_sql.columnas}>
                <td class="py-1 pr-3 font-mono text-gray-800">{c["nombre"]}</td>
                <td class="py-1 text-gray-400">{c["tipo_pg"]}</td>
              </tr>
            </tbody>
          </table>
          <p :if={@alcance == []} id="aviso-alcance" class="mt-3 bg-amber-50 text-amber-700 rounded-lg px-2.5 py-1.5">
            El SQL no entrega <code class="font-mono">branch_id</code>, <code class="font-mono">sales_unit_id</code> ni
            <code class="font-mono">inventory_id</code>: sus filas no se acotan al alcance de datos del usuario.
          </p>
          <p :if={@alcance != []} class="mt-3 bg-green-50 text-green-700 rounded-lg px-2.5 py-1.5">
            Se acota al alcance del usuario por: <span class="font-mono">{Enum.join(@alcance, ", ")}</span>.
          </p>
        </div>

        <div :if={@consulta_sql.uso == "servicio"} id="probar-servicio" class="bg-white border border-gray-200 rounded-2xl shadow-sm p-4 min-w-0">
          <div class="text-[11px] font-bold uppercase tracking-wide text-gray-400 mb-2">Probar</div>
          <p class="text-gray-500 mb-2">Se ejecuta con tu alcance de datos, igual que al llamarlo desde la pantalla.</p>
          <form id="form-probar" phx-change="editar_prueba" phx-submit="probar_servicio" class="flex flex-wrap items-end gap-2 mb-3">
            <label :for={p <- @consulta_sql.parametros} class="flex flex-col gap-0.5">
              <span class="font-mono text-gray-700">
                {p["nombre"]}<span :if={p["obligatorio"]} class="text-red-500">*</span>
                <span class="text-gray-400 font-sans">{etiqueta_tipo(p["tipo"])}</span>
              </span>
              <select :if={p["tipo"] == "booleano"} name={"valores[#{p["nombre"]}]"} id={"probar-#{p["nombre"]}"}
                class="border border-gray-300 rounded-lg px-2 py-1 focus:border-purple-400 focus:ring-2 focus:ring-purple-100 transition-colors">
                <option value="" selected={@prueba_valores[p["nombre"]] in [nil, ""]}>(default)</option>
                <option value="true" selected={@prueba_valores[p["nombre"]] == "true"}>Sí</option>
                <option value="false" selected={@prueba_valores[p["nombre"]] == "false"}>No</option>
              </select>
              <input :if={p["tipo"] != "booleano"} type="text" name={"valores[#{p["nombre"]}]"} id={"probar-#{p["nombre"]}"}
                value={@prueba_valores[p["nombre"]]} placeholder={ayuda_tipo(p["tipo"])} autocomplete="off"
                class="w-40 border border-gray-300 rounded-lg px-2 py-1 focus:border-purple-400 focus:ring-2 focus:ring-purple-100 transition-colors" />
            </label>
            <button type="submit" id="boton-probar" phx-disable-with="Ejecutando…"
              class="px-4 py-1.5 rounded-lg bg-teal-600 text-white font-semibold hover:bg-teal-700 transition-colors">
              Probar
            </button>
          </form>
          <%= cond do %>
            <% is_nil(@prueba_resultado) -> %>
              <p class="text-gray-400">Captura los valores y presiona Probar.</p>
            <% Map.has_key?(@prueba_resultado, :error) -> %>
              <p id="prueba-error" class="bg-red-50 text-red-700 rounded-lg px-2.5 py-1.5">{@prueba_resultado.error}</p>
            <% @prueba_resultado.filas == [] -> %>
              <p id="prueba-vacia" class="text-gray-400">Sin filas para esos valores.</p>
            <% true -> %>
              <p class="text-gray-500 mb-1">{length(@prueba_resultado.filas)} fila(s)</p>
              <div class="overflow-x-auto">
                <table id="prueba-resultado" class="min-w-full text-xs">
                  <thead class="bg-gray-50">
                    <tr>
                      <th :for={c <- @prueba_resultado.columnas} class="px-2 py-1.5 text-left font-semibold text-gray-500 font-mono">{c}</th>
                    </tr>
                  </thead>
                  <tbody class="divide-y divide-gray-100">
                    <tr :for={fila <- @prueba_resultado.filas} class="hover:bg-gray-50 transition-colors">
                      <td :for={c <- @prueba_resultado.columnas} class="px-2 py-1.5 text-gray-700 whitespace-nowrap">{valor_texto(fila[c])}</td>
                    </tr>
                  </tbody>
                </table>
              </div>
          <% end %>
        </div>

        <div :if={@consulta_sql.uso != "servicio"} class="bg-white border border-gray-200 rounded-2xl shadow-sm p-4 min-w-0">
          <div class="text-[11px] font-bold uppercase tracking-wide text-gray-400 mb-2">Vista previa (5 filas)</div>
          <%= cond do %>
            <% is_nil(@vista_previa) -> %>
              <p class="text-gray-400">Sin vista previa.</p>
            <% Map.has_key?(@vista_previa, :error) -> %>
              <p class="bg-red-50 text-red-700 rounded-lg px-2.5 py-1.5">{@vista_previa.error}</p>
            <% @vista_previa.filas == [] -> %>
              <p class="text-gray-400">La consulta no regresa filas por ahora.</p>
            <% true -> %>
              <div class="overflow-x-auto">
                <table id="vista-previa" class="min-w-full text-xs">
                  <thead class="bg-gray-50">
                    <tr>
                      <th :for={c <- @vista_previa.columnas} class="px-2 py-1.5 text-left font-semibold text-gray-500 font-mono">{c}</th>
                    </tr>
                  </thead>
                  <tbody class="divide-y divide-gray-100">
                    <tr :for={fila <- @vista_previa.filas} class="hover:bg-gray-50 transition-colors">
                      <td :for={valor <- fila} class="px-2 py-1.5 text-gray-700 whitespace-nowrap">{valor_texto(valor)}</td>
                    </tr>
                  </tbody>
                </table>
              </div>
          <% end %>
        </div>
      </div>

      <div :if={@consulta_sql.uso == "diccionario"} id="bc-autorizados" class="bg-white border border-gray-200 rounded-2xl shadow-sm p-4">
        <div class="text-[11px] font-bold uppercase tracking-wide text-gray-400 mb-1">BC que pueden usarla</div>
        <p class="text-gray-500 mb-3">
          Solo estos BC ven este Diccionario al configurar los filtros de sus campos. Aquí también se ve qué campos lo usan.
        </p>

        <form id="form-buscar-bc" phx-change="buscar_bc" phx-submit="buscar_bc" class="mb-2">
          <input type="text" name="busqueda" value={@busqueda_bc} phx-debounce="250" autocomplete="off"
            placeholder="Buscar un BC por nombre o etiqueta…"
            class="w-full border border-gray-300 rounded-lg px-2.5 py-1.5 focus:border-purple-400 focus:ring-2 focus:ring-purple-100 transition-colors" />
        </form>
        <div :if={@candidatos != []} class="mb-3 border border-gray-200 rounded-lg divide-y divide-gray-100">
          <div :for={c <- @candidatos} class="flex items-center justify-between px-2.5 py-1.5 hover:bg-gray-50 transition-colors">
            <span><span class="font-semibold text-gray-800">{c.etiqueta}</span> <span class="font-mono text-gray-400">{c.nombre}</span></span>
            <button type="button" phx-click="autorizar_bc" phx-value-bc={c.nombre} id={"autorizar-#{c.nombre}"}
              class="text-purple-700 hover:text-purple-900 font-semibold">+ Autorizar</button>
          </div>
        </div>
        <p :if={@bc_error} id="bc-error" class="mb-2 bg-red-50 text-red-700 rounded-lg px-2.5 py-1.5">{@bc_error}</p>

        <p :if={@consulta_sql.bcs_autorizados == []} class="text-gray-400">Ningún BC autorizado todavía.</p>
        <table :if={@consulta_sql.bcs_autorizados != []} id="tabla-autorizados" class="min-w-full text-xs">
          <thead class="bg-gray-50">
            <tr>
              <th class="px-2 py-1.5 text-left font-semibold text-gray-500">BC</th>
              <th class="px-2 py-1.5 text-left font-semibold text-gray-500">Campos que la usan</th>
              <th class="px-2 py-1.5"></th>
            </tr>
          </thead>
          <tbody class="divide-y divide-gray-100">
            <tr :for={bc <- @consulta_sql.bcs_autorizados} id={"autorizado-#{bc}"}>
              <td class="px-2 py-1.5 font-mono text-gray-800">{bc}</td>
              <td class="px-2 py-1.5 text-gray-600">
                <%= case Enum.filter(@usos, &(&1.catalogo == bc)) do %>
                  <% [] -> %><span class="text-gray-400">Sin uso todavía</span>
                  <% usos -> %>{Enum.map_join(usos, ", ", &(&1.etiqueta || &1.campo))}
                <% end %>
              </td>
              <td class="px-2 py-1.5 text-right">
                <button type="button" phx-click="desautorizar_bc" phx-value-bc={bc} class="text-red-600 hover:text-red-800 font-semibold">Quitar</button>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
    """
  end

  defp tipos_parametro, do: ServicioEndpoint.tipos()
  defp ayuda_tipo("lista_enteros"), do: "1,2,3"
  defp ayuda_tipo("fecha"), do: "AAAA-MM-DD"
  defp ayuda_tipo("decimal"), do: "12.50"
  defp ayuda_tipo(_tipo), do: ""

  defp etiqueta_uso("diccionario"), do: "Diccionario"
  defp etiqueta_uso("servicio"), do: "Servicio"
  defp etiqueta_uso(_uso), do: "Consulta"

  defp valor_texto(nil), do: "—"
  defp valor_texto(%Decimal{} = d), do: Decimal.to_string(d, :normal)
  defp valor_texto(valor) when is_binary(valor), do: valor
  defp valor_texto(valor), do: to_string(valor)

  attr :header, :map, required: true
  attr :consulta_sql, :map, required: true

  defp panel_contrato(assigns) do
    ejemplo_json = """
    {
      "meta_campos": [
        { "clave": "<columna>", "tipo": "..." },
        ...
      ],
      "data": [
        { "<columna>": <valor>, ... },
        ...
      ],
      "paginacion": { "pagina": 1, "por_pagina": 25, "total_filas": 0, "total_paginas": 1 }
    }
    """

    assigns = assign(assigns, :ejemplo_json, ejemplo_json)

    ~H"""
    <div class="flex flex-col gap-4">
      <div class="bg-white border border-gray-200 rounded-2xl shadow-sm p-4">
        <div class="text-[11px] font-bold uppercase tracking-wide text-gray-400 mb-2">Endpoint</div>
        <div class="flex items-center gap-2 mb-3">
          <span class="text-[10px] font-bold px-1.5 py-0.5 rounded bg-emerald-100 text-emerald-700">GET</span>
          <code id="contrato-ruta" class="font-mono text-xs bg-gray-100 px-2 py-1 rounded">/api/{@header.schema_context_name}</code>
        </div>
        <p class="text-xs text-gray-500">
          Solo lectura: no existen <code class="font-mono">POST</code>/<code class="font-mono">PUT</code>/<code class="font-mono">DELETE</code> para una SQL View.
          Aplica la misma seguridad que el resto de la API (<code class="font-mono">/api/*</code>) y el alcance de datos del usuario.
        </p>
      </div>

      <div class="bg-white border border-gray-200 rounded-2xl shadow-sm p-4">
        <div class="text-[11px] font-bold uppercase tracking-wide text-gray-400 mb-2">Parámetros (query string)</div>
        <table class="min-w-full text-xs">
          <tbody class="divide-y divide-gray-100">
            <tr>
              <td class="py-1.5 pr-4 font-mono text-gray-700">pagina</td>
              <td class="py-1.5 text-gray-500">Página a traer. Default 1.</td>
            </tr>
            <tr>
              <td class="py-1.5 pr-4 font-mono text-gray-700">por_pagina</td>
              <td class="py-1.5 text-gray-500">Filas por página. Default 25, máximo 100.</td>
            </tr>
          </tbody>
        </table>
        <p class="text-xs text-gray-500 mt-2">Sin filtros: el SQL de una SQL View es fijo.</p>
      </div>

      <div class="bg-white border border-gray-200 rounded-2xl shadow-sm p-4">
        <div class="text-[11px] font-bold uppercase tracking-wide text-gray-400 mb-2">Columnas</div>
        <p :if={@consulta_sql.columnas == []} class="text-gray-400">Todavía no hay SQL guardado.</p>
        <div class="flex flex-wrap gap-1.5">
          <span :for={c <- @consulta_sql.columnas} class="font-mono bg-gray-100 rounded px-1.5 py-0.5">{c["nombre"]} <span class="text-gray-400">{c["tipo"]}</span></span>
        </div>
      </div>

      <div class="bg-white border border-gray-200 rounded-2xl shadow-sm p-4">
        <div class="text-[11px] font-bold uppercase tracking-wide text-gray-400 mb-2">Ejemplo y forma de la respuesta</div>
        <div class="bg-gray-900 text-gray-100 rounded-lg px-3 py-2 overflow-x-auto font-mono text-xs mb-2">
          GET /api/{@header.schema_context_name}?pagina=1&por_pagina=25
        </div>
        <pre class="bg-gray-900 text-gray-100 rounded-lg px-3 py-2 text-[11px] overflow-x-auto"><code>{@ejemplo_json}</code></pre>
      </div>
    </div>
    """
  end
end
