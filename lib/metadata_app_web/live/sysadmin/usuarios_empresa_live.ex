defmodule MetadataAppWeb.Sysadmin.UsuariosEmpresaLive do
  @moduledoc """
  Administrador de usuarios: maestro-detalle (rediseño 2026-08-02, a pedido
  explícito con mockup) — lista buscable de usuarios de la empresa activa a
  la izquierda, y a la derecha 4 pestañas para el usuario seleccionado:

    * Generales — alias/email (por ahora solo lectura; "Desactivar cuenta"
      queda para una entrega aparte, ver memoria del proyecto).
    * Empresas — TODAS las que pertenece (no solo la activa) + agregar a
      CUALQUIER empresa del sistema (decisión explícita: no se restringe a
      "solo las empresas donde yo también soy admin" — no hay todavía un
      concepto de "super admin" dueño de esa regla).
    * Roles — eje invertido de RolDetalleLive/CatalogoPermisosLive (ahí se
      fija un rol/catálogo y se listan usuarios; acá se fija un usuario y
      se listan sus roles). Alcance: solo los roles de la empresa ACTIVA
      (un usuario con varias empresas tiene roles distintos por cada una —
      mostrar todas mezcladas confundiría más de lo que ayuda). Lista
      vertical de los ya concedidos (siempre chica) + buscador acotado
      (Permissions.buscar_roles/3, mismo criterio que buscar_catalogos/2)
      para agregar uno nuevo — pensado para cientos de roles por empresa,
      cargar la lista completa cada vez no escala.
    * BC — de solo lectura: catálogos que el usuario puede "leer" por
      herencia de sus roles en la empresa activa (mismo permiso que ya
      poda el menú, ver MenuLayout.podar_menu_por_permisos/1).
    * Alcance — Fase 7 del modelo de Alcance de Datos (2026-08-11): QUÉ
      branches/sales_units/inventory_locations puede VER/OPERAR este
      usuario (la asignación N:N de Autenticacion.asignar_branch/2 etc.,
      la que hidrata Scope.branches_permitidos/sales_units_permitidas/
      inventory_locations_permitidas). Distinto del "alcance_tipo" por
      rol (eso se configura en CatalogoPermisosLive, es "QUÉ TIPO de
      filtro aplica", no "cuáles ids concretos" — ver moduledoc de
      MetadataApp.Autenticacion.Scope). Árbol Branch -> {SalesUnit,
      InventoryLocation}, un toggle por nodo, mismo patrón visual que las
      demás pestañas (botón "Asignado"/"+ Asignar", no checkbox real).
  """

  use MetadataAppWeb, :live_view_admin

  on_mount {MetadataAppWeb.UsuarioAuth, :mount_current_scope}
  on_mount {MetadataAppWeb.Hooks.Autorizacion, {"rbac_admin", "leer"}}

  alias MetadataApp.Autenticacion
  alias MetadataApp.Autenticacion.Usuario
  alias MetadataApp.Permissions
  alias MetadataApp.BusinessProcessBuilder.MetaSchemaContext
  alias MetadataAppWeb.{AdminNav, UsuarioAuth}

  @menu [
    %{tipo: :pagina, id: "bc_list", label: "BC List", nav: "/sysadmin/bc-list"},
    %{tipo: :pagina, id: "buscar_trn", label: "Buscar TRN", nav: "/sysadmin/buscar-trn"},
    %{tipo: :pagina, id: "tepache", label: "Tepache Exp/Imp", nav: "/sysadmin/tepache"},
    %{tipo: :pagina, id: "roles", label: "Roles y Usuarios", nav: "/sysadmin/roles"},
    %{tipo: :pagina, id: "usuarios_empresa", label: "Usuarios", nav: "/sysadmin/usuarios"},
    %{tipo: :pagina, id: "empresas", label: "Empresas", nav: "/sysadmin/empresas"},
    %{tipo: :pagina, id: "credenciales", label: "Credenciales", nav: "/sysadmin/credenciales"},
    %{tipo: :pagina, id: "acciones_externas", label: "Acciones externas", nav: "/sysadmin/acciones-externas"},
    %{tipo: :pagina, id: "jerarquia", label: "Jerarquía organizacional", nav: "/sysadmin/jerarquia"}
  ]

  def mount(_params, _session, socket) do
    usuario = socket.assigns.current_scope.usuario

    {:ok,
     socket
     |> assign(:current_page, "usuarios_empresa")
     |> assign(:menu_items, AdminNav.filtrar_menu(@menu))
     |> assign(:sidebar_open, false)
     |> assign(:show_programacion_children, false)
     |> assign(:show_clientes_children, false)
     |> assign(:show_prettycore_children, false)
     |> assign(:busqueda, "")
     |> assign(:usuario_seleccionado, nil)
     |> assign(:roles_concedidos, [])
     |> assign(:busqueda_rol, "")
     |> assign(:roles_busqueda_resultado, [])
     |> assign(:empresas_estado, [])
     |> assign(:empresa_para_agregar, nil)
     |> assign(:bcs_lectura, [])
     |> assign(:jerarquia_alcance, [])
     |> assign(:alias_form, nil)
     |> assign(:crear_usuario_error, nil)
     # empresa_en_foco: cuál empresa está gestionando esta pantalla (usuarios/
     # roles/BC listados) — DISTINTA de current_scope.empresa_activa (la
     # empresa real de la sesión, la que ve el resto de la app). Para un
     # admin normal siempre son la misma. Para super_admin, un <select>
     # (ver render) la cambia sin tocar la sesión — así puede gestionar
     # CUALQUIER empresa sin el rodeo de unirse+activar cada vez.
     |> assign(:empresa_en_foco, socket.assigns.current_scope.empresa_activa)
     |> assign(:todas_las_empresas, if(usuario.super_admin, do: Autenticacion.listar_empresas(), else: []))
     |> assign(:usuarios_sin_empresa, Autenticacion.listar_usuarios_sin_empresa())
     |> cargar_usuarios()}
  end

  # Solo super_admin puede cambiar qué empresa gestiona esta pantalla — el
  # <select> del render ya está oculto para cualquier otro, pero el
  # handler se defiende igual del lado servidor (nunca confiar solo en
  # que el cliente no mande el evento).
  def handle_event("cambiar_empresa_en_foco", %{"empresa_id" => empresa_id}, socket) do
    if socket.assigns.current_scope.usuario.super_admin do
      empresa = Enum.find(socket.assigns.todas_las_empresas, &(&1.id == String.to_integer(empresa_id)))

      {:noreply,
       socket
       |> assign(:empresa_en_foco, empresa)
       |> assign(
         usuario_seleccionado: nil,
         roles_concedidos: [],
         busqueda_rol: "",
         roles_busqueda_resultado: [],
         empresas_estado: [],
         bcs_lectura: [],
         jerarquia_alcance: []
       )
       |> cargar_usuarios()}
    else
      {:noreply, socket}
    end
  end

  def handle_event("change_page", %{"id" => id}, socket) do
    AdminNav.handle_nav(id, socket, "usuarios_empresa")
  end

  def handle_event("buscar_usuario", %{"value" => texto}, socket) do
    {:noreply, assign(socket, :busqueda, texto)}
  end

  # Alta directa desde el admin (reemplaza el autoregistro público, cerrado
  # 2026-08-03 — ver docs/roadmap o memoria del proyecto): valida SOLO el
  # formato acá (validate_unique: false — a diferencia del registro
  # público, un email ya existente NO es un error, agregar_usuario_a_empresa/2
  # simplemente lo suma a esta empresa) antes de tocar la base, para no
  # pisar el match rígido `{:ok, _} = register_usuario(...)` de esa función
  # con un email mal formado.
  def handle_event("crear_usuario", %{"email" => email}, socket) do
    email = String.trim(email)

    case Autenticacion.change_usuario_email(%Usuario{}, %{"email" => email}, validate_unique: false) do
      %{valid?: true} ->
        empresa_id = socket.assigns.empresa_en_foco.id
        # agregar_usuario_a_empresa/2 no devuelve consistentemente el
        # %Usuario{} (según la rama interna, puede devolver el
        # %UsuarioEmpresa{} recién insertado) — se vuelve a buscar por
        # email para tener siempre el struct correcto acá.
        Autenticacion.agregar_usuario_a_empresa(email, empresa_id)
        usuario = Autenticacion.get_usuario_by_email(email)
        Autenticacion.deliver_login_instructions(usuario, &url(~p"/meta_schema_usuario/log-in/#{&1}"))

        {:noreply,
         socket
         |> put_flash(:info, "Se envió un correo a #{email} con instrucciones para entrar.")
         |> assign(:crear_usuario_error, nil)
         |> assign(:usuario_seleccionado, usuario)
         |> cargar_usuarios()
         |> cargar_detalle_usuario()}

      changeset ->
        {:noreply, assign(socket, :crear_usuario_error, MetadataApp.MetaErrores.traducir(changeset)[:email] |> List.wrap() |> List.first())}
    end
  end

  # Reemplaza el alta "escribir cualquier email" (que además creaba la
  # cuenta desde cero) — decisión explícita de producto: como el registro
  # público ya existe (magic-link, self-service), no hace falta que el
  # admin pueda inventar cuentas nuevas acá; solo elige entre las que YA
  # se registraron y todavía no tienen empresa.
  def handle_event("agregar_usuario_sin_empresa", %{"id" => id}, socket) do
    empresa_id = socket.assigns.empresa_en_foco.id
    usuario = Enum.find(socket.assigns.usuarios_sin_empresa, &(&1.id == String.to_integer(id)))

    Autenticacion.agregar_usuario_a_empresa(usuario.email, empresa_id)

    {:noreply,
     socket
     |> assign(:usuarios_sin_empresa, Autenticacion.listar_usuarios_sin_empresa())
     |> cargar_usuarios()}
  end

  # Rechazar = eliminar la cuenta directo (a diferencia de "quitar" en
  # cualquier otro lado del RBAC, no hay soft-delete acá: Usuario no tiene
  # delete_guid). Seguro porque, por definición de esta lista, todavía no
  # tiene ninguna empresa/rol asociado — nada que perder salvo la cuenta
  # misma, y si esa persona quiere entrar de verdad puede registrarse de
  # nuevo cuando corresponda.
  def handle_event("rechazar_usuario_sin_empresa", %{"id" => id}, socket) do
    usuario = Enum.find(socket.assigns.usuarios_sin_empresa, &(&1.id == String.to_integer(id)))
    Autenticacion.eliminar_usuario(usuario)
    {:noreply, assign(socket, :usuarios_sin_empresa, Autenticacion.listar_usuarios_sin_empresa())}
  end

  # Mismo patrón que UsuarioLive.Settings (validate_alias/update_alias),
  # acá aplicado al usuario SELECCIONADO en vez de current_scope.usuario —
  # sin sudo mode ni confirmación, no es un dato sensible.
  def handle_event("validate_alias", %{"usuario" => params}, socket) do
    alias_form =
      socket.assigns.usuario_seleccionado
      |> Autenticacion.change_usuario_alias(params)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, :alias_form, alias_form)}
  end

  def handle_event("guardar_alias", %{"usuario" => params}, socket) do
    case Autenticacion.update_usuario_alias(socket.assigns.usuario_seleccionado, params) do
      {:ok, usuario} ->
        {:noreply,
         socket
         |> assign(:usuario_seleccionado, usuario)
         |> assign(:alias_form, to_form(Autenticacion.change_usuario_alias(usuario)))
         |> cargar_usuarios()}

      {:error, changeset} ->
        {:noreply, assign(socket, :alias_form, to_form(changeset, action: :insert))}
    end
  end

  def handle_event("seleccionar_usuario", %{"id" => id}, socket) do
    usuario = Enum.find(socket.assigns.usuarios, &(&1.id == String.to_integer(id)))
    {:noreply, socket |> assign(:usuario_seleccionado, usuario) |> cargar_detalle_usuario()}
  end

  def handle_event("cerrar_detalle", _params, socket) do
    {:noreply,
     assign(socket,
       usuario_seleccionado: nil,
       roles_concedidos: [],
       busqueda_rol: "",
       roles_busqueda_resultado: [],
       empresas_estado: [],
       bcs_lectura: [],
       jerarquia_alcance: []
     )}
  end

  # Uso administrativo (despido, salida de urgencia): corta acceso YA, sin
  # esperar a que el token expire por tiempo (ver
  # UsuarioToken.@session_validity_in_hours, 2026-08-06). Borra los tokens
  # de sesión Y desconecta cualquier socket LiveView ya abierto -- lo uno
  # sin lo otro no alcanza, un socket ya conectado sigue vivo hasta el
  # próximo request aunque su token en DB ya no exista.
  def handle_event("cerrar_sesiones_de_usuario", _params, socket) do
    usuario = socket.assigns.usuario_seleccionado
    tokens = Autenticacion.revocar_sesiones_de_usuario(usuario.id)
    UsuarioAuth.disconnect_sessions(tokens)

    {:noreply, put_flash(socket, :info, "Se cerraron todas las sesiones de #{usuario.email}.")}
  end

  def handle_event("quitar_rol_de_usuario", %{"rol_id" => rol_id}, socket) do
    %{usuario_seleccionado: usuario, empresa_en_foco: empresa} = socket.assigns
    Permissions.revocar_rol(usuario.id, String.to_integer(rol_id), empresa.id)
    {:noreply, cargar_detalle_usuario(socket)}
  end

  def handle_event("buscar_rol", %{"value" => texto}, socket) do
    %{empresa_en_foco: empresa} = socket.assigns
    concedidos_ids = MapSet.new(socket.assigns.roles_concedidos, & &1.id)

    resultado =
      empresa.id
      |> Permissions.buscar_roles(texto)
      |> Enum.reject(&MapSet.member?(concedidos_ids, &1.id))

    {:noreply, assign(socket, busqueda_rol: texto, roles_busqueda_resultado: resultado)}
  end

  def handle_event("agregar_rol_a_usuario", %{"rol_id" => rol_id}, socket) do
    %{usuario_seleccionado: usuario, empresa_en_foco: empresa} = socket.assigns
    Permissions.asignar_rol(usuario.id, String.to_integer(rol_id), empresa.id)
    {:noreply, socket |> assign(busqueda_rol: "", roles_busqueda_resultado: []) |> cargar_detalle_usuario()}
  end

  def handle_event("elegir_empresa_para_agregar", %{"empresa_id" => empresa_id}, socket) do
    {:noreply, assign(socket, :empresa_para_agregar, empresa_id)}
  end

  def handle_event("agregar_empresa_a_usuario", _params, socket) do
    %{usuario_seleccionado: usuario, empresa_para_agregar: empresa_id} = socket.assigns

    socket =
      case empresa_id do
        vazio when vazio in [nil, ""] ->
          socket

        empresa_id ->
          Autenticacion.agregar_usuario_a_empresa(usuario.email, String.to_integer(empresa_id))
          socket |> assign(:empresa_para_agregar, nil) |> cargar_usuarios() |> cargar_detalle_usuario()
      end

    {:noreply, socket}
  end

  # Quitar la empresa EN FOCO (la misma que arma la lista de la izquierda)
  # deja al usuario seleccionado fuera de esa lista — a diferencia de
  # cualquier otra empresa (donde solo se refresca su pestaña Empresas).
  def handle_event("quitar_empresa_de_usuario", %{"empresa_id" => empresa_id}, socket) do
    %{usuario_seleccionado: usuario, empresa_en_foco: empresa_en_foco} = socket.assigns
    empresa_id = String.to_integer(empresa_id)

    Autenticacion.remover_usuario_de_empresa(usuario.id, empresa_id)
    socket = assign(socket, :usuarios_sin_empresa, Autenticacion.listar_usuarios_sin_empresa())

    if empresa_id == empresa_en_foco.id do
      {:noreply,
       socket
       |> assign(
         usuario_seleccionado: nil,
         roles_concedidos: [],
         busqueda_rol: "",
         roles_busqueda_resultado: [],
         empresas_estado: [],
         bcs_lectura: [],
         jerarquia_alcance: []
       )
       |> cargar_usuarios()}
    else
      {:noreply, cargar_detalle_usuario(socket)}
    end
  end

  # Fase 7 del modelo de Alcance de Datos -- 3 handlers gemelos, uno por
  # dimensión de la jerarquía. "asignado" llega como el estado ACTUAL
  # (calculado server-side al armar jerarquia_alcance, no confiar en un
  # valor que el cliente pudiera mandar distinto): si ya está asignado,
  # el click revoca; si no, asigna. asignar_*/2 es idempotente
  # (on_conflict: :nothing), así que no hace falta chequear de nuevo acá.
  def handle_event("toggle_branch_alcance", %{"branch_id" => branch_id, "asignado" => asignado}, socket) do
    usuario_id = socket.assigns.usuario_seleccionado.id
    branch_id = String.to_integer(branch_id)

    if asignado == "true" do
      Autenticacion.revocar_branch(usuario_id, branch_id)
    else
      Autenticacion.asignar_branch(usuario_id, branch_id)
    end

    {:noreply, cargar_detalle_usuario(socket)}
  end

  def handle_event("toggle_sales_unit_alcance", %{"sales_unit_id" => sales_unit_id, "asignado" => asignado}, socket) do
    usuario_id = socket.assigns.usuario_seleccionado.id
    sales_unit_id = String.to_integer(sales_unit_id)

    if asignado == "true" do
      Autenticacion.revocar_sales_unit(usuario_id, sales_unit_id)
    else
      Autenticacion.asignar_sales_unit(usuario_id, sales_unit_id)
    end

    {:noreply, cargar_detalle_usuario(socket)}
  end

  def handle_event("toggle_inventory_location_alcance", %{"inventory_id" => inventory_id, "asignado" => asignado}, socket) do
    usuario_id = socket.assigns.usuario_seleccionado.id
    inventory_id = String.to_integer(inventory_id)

    if asignado == "true" do
      Autenticacion.revocar_inventory_location(usuario_id, inventory_id)
    else
      Autenticacion.asignar_inventory_location(usuario_id, inventory_id)
    end

    {:noreply, cargar_detalle_usuario(socket)}
  end

  defp cargar_usuarios(socket) do
    empresa_id = socket.assigns.empresa_en_foco.id
    assign(socket, :usuarios, Autenticacion.listar_usuarios_de_empresa(empresa_id))
  end

  defp cargar_detalle_usuario(socket) do
    %{usuario_seleccionado: usuario, empresa_en_foco: empresa} = socket.assigns

    roles_concedidos = Permissions.roles_de_usuario(usuario.id, empresa.id)

    empresas_del_usuario = Autenticacion.empresas_de_usuario(usuario.id)
    empresas_del_usuario_ids = MapSet.new(empresas_del_usuario, & &1.id)
    empresas_disponibles = Enum.reject(Autenticacion.listar_empresas(), &MapSet.member?(empresas_del_usuario_ids, &1.id))

    bcs_lectura =
      usuario.id
      |> Permissions.permisos_de_usuario(empresa.id)
      |> Enum.filter(&(&1.accion == "leer"))
      |> Enum.map(& &1.recurso)
      |> Enum.uniq()
      |> MetaSchemaContext.obtener_headers_por_nombres()
      |> Enum.sort_by(& &1.schema_context_label)

    socket
    |> assign(:roles_concedidos, roles_concedidos)
    |> assign(:busqueda_rol, "")
    |> assign(:roles_busqueda_resultado, [])
    |> assign(:empresas_estado, empresas_del_usuario)
    |> assign(:empresas_disponibles, empresas_disponibles)
    |> assign(:bcs_lectura, bcs_lectura)
    |> assign(:jerarquia_alcance, cargar_jerarquia_alcance(usuario, empresa))
    |> assign(:alias_form, to_form(Autenticacion.change_usuario_alias(usuario)))
  end

  # Árbol Branch -> {SalesUnit, InventoryLocation} de la empresa en foco,
  # con qué nodos tiene asignados el usuario (Fase 7). Se arma desde 0 en
  # cada carga -- son listas chicas (decenas, no miles, por empresa) y así
  # se evita cualquier desincronización con lo que Autenticacion.alcance_de_usuario/2
  # ya reporta como fuente de verdad.
  defp cargar_jerarquia_alcance(usuario, empresa) do
    %{
      branches_permitidos: branch_ids,
      sales_units_permitidas: sales_unit_ids,
      inventory_locations_permitidas: inventory_ids
    } = Autenticacion.alcance_de_usuario(usuario.id, empresa.id)

    branch_ids = MapSet.new(branch_ids)
    sales_unit_ids = MapSet.new(sales_unit_ids)
    inventory_ids = MapSet.new(inventory_ids)

    empresa.id
    |> Autenticacion.listar_branches()
    |> Enum.map(fn branch ->
      %{
        branch: branch,
        asignado: MapSet.member?(branch_ids, branch.id),
        sales_units:
          branch.id
          |> Autenticacion.listar_sales_units()
          |> Enum.map(&%{sales_unit: &1, asignado: MapSet.member?(sales_unit_ids, &1.id)}),
        inventory_locations:
          branch.id
          |> Autenticacion.listar_inventory_locations()
          |> Enum.map(&%{inventory_location: &1, asignado: MapSet.member?(inventory_ids, &1.id)})
      }
    end)
  end

  defp usuarios_filtrados(usuarios, ""), do: usuarios

  defp usuarios_filtrados(usuarios, busqueda) do
    texto = String.downcase(busqueda)
    Enum.filter(usuarios, &String.contains?(String.downcase(&1.email), texto))
  end

  def render(assigns) do
    assigns = assign(assigns, :usuarios_visibles, usuarios_filtrados(assigns.usuarios, assigns.busqueda))

    ~H"""
    <div class="p-6">
      <div class="flex items-center gap-2 mb-4">
        <.link navigate={~p"/"} title="Volver al inicio"
          class="w-7 h-7 flex items-center justify-center rounded-lg text-gray-500 hover:bg-gray-100 hover:text-gray-700 transition-colors shrink-0">
          <span class="material-symbols-outlined" style="font-size: 18px">arrow_back</span>
        </.link>
        <div>
          <h1 class="text-2xl font-bold">Administrador de usuarios</h1>
          <p class="text-xs text-gray-400">{@empresa_en_foco.nombre}</p>
        </div>
      </div>

      <!-- Selector de empresa gestionada — solo super_admin, y sin tocar
           la empresa ACTIVA de la sesión (esa la cambia el selector de
           siempre en el topbar). Sin esto, gestionar otra empresa exigía
           unirse+activar antes de poder ver sus usuarios. -->
      <div :if={@current_scope.usuario.super_admin} class="mb-4">
        <label class="text-xs font-semibold text-gray-500 mr-2">Gestionando:</label>
        <form phx-change="cambiar_empresa_en_foco" class="inline">
          <select name="empresa_id" class="border border-gray-300 rounded-lg px-2 py-1 text-sm text-gray-900">
            <option :for={empresa <- @todas_las_empresas} value={empresa.id} selected={empresa.id == @empresa_en_foco.id}>
              {empresa.nombre}
            </option>
          </select>
        </form>
      </div>

      <div class="flex gap-4 items-start">
        <!-- Izquierda: buscador + lista + alta -->
        <div class="w-72 flex-shrink-0 border border-gray-200 rounded-xl overflow-hidden flex flex-col" style="height: 70vh">
          <div class="p-2 border-b border-gray-100">
            <input
              type="text"
              value={@busqueda}
              phx-keyup="buscar_usuario"
              phx-debounce="200"
              placeholder="Buscar..."
              class="w-full border border-gray-300 rounded-lg px-3 py-1.5 text-sm text-gray-900"
            />
          </div>

          <!-- Alta directa por el admin — reemplaza el autoregistro
               público (cerrado): la cuenta nace ya asociada a la empresa
               activa y recibe el correo de magic-link al toque, sin
               solicitud previa que aceptar/rechazar. -->
          <div class="p-2 border-b border-gray-100">
            <form phx-submit="crear_usuario" class="flex gap-1">
              <input
                type="email"
                name="email"
                placeholder="nuevo@correo.com"
                required
                class="flex-1 min-w-0 border border-gray-300 rounded-lg px-2 py-1.5 text-sm text-gray-900"
              />
              <button type="submit" class="px-2 py-1.5 rounded-lg bg-purple-600 text-white text-xs font-semibold hover:bg-purple-700 whitespace-nowrap">
                + Crear
              </button>
            </form>
            <p :if={@crear_usuario_error} class="text-[11px] text-red-600 mt-1">{@crear_usuario_error}</p>
          </div>

          <div class="flex-1 overflow-y-auto">
            <button
              :for={usuario <- @usuarios_visibles}
              type="button"
              phx-click="seleccionar_usuario"
              phx-value-id={usuario.id}
              class={[
                "w-full text-left px-3 py-2 text-sm border-b border-gray-50 transition-colors",
                @usuario_seleccionado && @usuario_seleccionado.id == usuario.id && "bg-purple-50 text-purple-700 font-semibold",
                !(@usuario_seleccionado && @usuario_seleccionado.id == usuario.id) && "text-gray-700 hover:bg-gray-50"
              ]}
            >
              {usuario.email}
              <span :if={!usuario.confirmed_at} class="block text-[10px] text-amber-600">Sin confirmar</span>
            </button>
            <p :if={@usuarios_visibles == []} class="px-3 py-6 text-center text-xs text-gray-400">
              {if @busqueda == "", do: "Todavía no hay usuarios en esta empresa.", else: "Sin resultados."}
            </p>
          </div>

          <!-- Usuarios ya registrados (self-service, magic-link) que
               todavía no pertenecen a ninguna empresa — reemplaza el alta
               "escribir cualquier email" (decisión de producto 2026-08-02:
               el registro público ya cubre "cuenta nueva", acá solo se
               resuelve "¿quién se anotó y nadie le dio acceso todavía?"). -->
          <div class="p-2 border-t border-gray-100 max-h-40 overflow-y-auto">
            <p class="text-[11px] font-semibold text-gray-400 uppercase tracking-wide px-1 mb-1">Sin empresa</p>
            <div :for={usuario <- @usuarios_sin_empresa} class="flex items-center justify-between gap-2 px-1 py-1 text-xs">
              <span class="text-gray-700 truncate">{usuario.email}</span>
              <div class="flex-shrink-0 flex items-center gap-2">
                <button type="button" phx-click="agregar_usuario_sin_empresa" phx-value-id={usuario.id}
                  class="text-purple-700 font-semibold hover:underline">
                  + Agregar
                </button>
                <button type="button" phx-click="rechazar_usuario_sin_empresa" phx-value-id={usuario.id}
                  data-confirm={"¿Rechazar y eliminar la cuenta de #{usuario.email}? No se puede deshacer."}
                  class="text-red-600 hover:underline">
                  Rechazar
                </button>
              </div>
            </div>
            <p :if={@usuarios_sin_empresa == []} class="text-xs text-gray-400 px-1 py-1">Nadie esperando acceso.</p>
          </div>
        </div>

        <!-- Derecha: detalle del usuario seleccionado, 4 pestañas -->
        <div class="flex-1 border border-gray-200 rounded-xl p-4" style="min-height: 70vh">
          <%= if @usuario_seleccionado do %>
            <div class="flex items-center justify-between mb-3">
              <h2 class="text-sm font-bold text-gray-900">{@usuario_seleccionado.email}</h2>
              <button type="button" phx-click="cerrar_detalle" class="text-xs text-gray-500 hover:underline">Cerrar</button>
            </div>

            <.tabs_motor id="usuario-detalle" tabs={[
              %{key: "generales", label: "Generales"},
              %{key: "empresas", label: "Empresas"},
              %{key: "roles", label: "Roles"},
              %{key: "bc", label: "BC"},
              %{key: "alcance", label: "Alcance"}
            ]} />

            <div id="usuario-detalle-panel-generales">
              <dl class="text-sm space-y-2">
                <div>
                  <dt class="text-xs text-gray-400">Email</dt>
                  <dd class="text-gray-900">{@usuario_seleccionado.email}</dd>
                </div>
                <div>
                  <dt class="text-xs text-gray-400 mb-1">Alias</dt>
                  <.form for={@alias_form} id="alias_form" phx-submit="guardar_alias" phx-change="validate_alias" class="flex items-center gap-2">
                    <input
                      type="text"
                      name={@alias_form[:alias].name}
                      value={@alias_form[:alias].value}
                      maxlength="40"
                      placeholder="Sin alias"
                      class="border border-gray-300 rounded-lg px-2 py-1 text-sm text-gray-900"
                    />
                    <button type="submit" class="px-3 py-1 rounded-lg bg-purple-600 text-white text-xs font-semibold hover:bg-purple-700">
                      Guardar
                    </button>
                  </.form>
                  <p :if={@alias_form.errors[:alias]} class="text-[11px] text-red-600 mt-1">
                    {elem(@alias_form.errors[:alias], 0)}
                  </p>
                </div>
                <div>
                  <dt class="text-xs text-gray-400">Cuenta</dt>
                  <dd>
                    <span :if={@usuario_seleccionado.confirmed_at} class="inline-flex items-center px-2 py-0.5 rounded-full text-xs font-semibold bg-green-50 text-green-700 border border-green-100">
                      Confirmada
                    </span>
                    <span :if={!@usuario_seleccionado.confirmed_at} class="inline-flex items-center px-2 py-0.5 rounded-full text-xs font-semibold bg-amber-50 text-amber-700 border border-amber-100">
                      Sin confirmar
                    </span>
                  </dd>
                </div>
                <div>
                  <dt class="text-xs text-gray-400 mb-1">Sesiones activas</dt>
                  <button type="button" phx-click="cerrar_sesiones_de_usuario"
                    data-confirm={"¿Cerrar TODAS las sesiones activas de #{@usuario_seleccionado.email} en cualquier dispositivo? Va a tener que volver a loguearse."}
                    class="px-3 py-1 rounded-lg bg-red-50 text-red-700 border border-red-100 text-xs font-semibold hover:bg-red-100">
                    Cerrar todas las sesiones
                  </button>
                </div>
              </dl>
              <p class="text-xs text-gray-400 mt-4">Desactivar/bloquear cuenta: próximamente.</p>
            </div>

            <div id="usuario-detalle-panel-empresas" class="hidden">
              <ul class="divide-y divide-gray-100 border border-gray-100 rounded-lg mb-3">
                <li :for={empresa <- @empresas_estado} class="flex items-center justify-between px-3 py-2 text-sm">
                  <span class="text-gray-800">
                    {empresa.nombre}
                    <span :if={empresa.id == @current_scope.empresa_activa.id} class="text-[10px] text-purple-600 font-semibold ml-1">(activa)</span>
                  </span>
                  <button type="button" phx-click="quitar_empresa_de_usuario" phx-value-empresa_id={empresa.id}
                    data-confirm={"¿Quitar a #{@usuario_seleccionado.email} de #{empresa.nombre}? Pierde cualquier rol que tenga ahí."}
                    class="text-xs text-red-600 hover:underline">
                    Quitar
                  </button>
                </li>
                <li :if={@empresas_estado == []} class="px-3 py-4 text-center text-xs text-gray-400">Sin empresas.</li>
              </ul>

              <form phx-submit="agregar_empresa_a_usuario" phx-change="elegir_empresa_para_agregar" class="flex gap-2">
                <select name="empresa_id" class="flex-1 border border-gray-300 rounded-lg px-2 py-1.5 text-sm">
                  <option value="">— Elegir empresa —</option>
                  <option :for={empresa <- @empresas_disponibles} value={empresa.id}>{empresa.nombre}</option>
                </select>
                <button type="submit" class="px-3 py-1.5 rounded-lg bg-purple-600 text-white text-xs font-semibold hover:bg-purple-700">
                  Agregar
                </button>
              </form>
            </div>

            <div id="usuario-detalle-panel-roles" class="hidden">
              <p class="text-xs text-gray-400 mb-2">Roles en {@empresa_en_foco.nombre}.</p>

              <ul class="divide-y divide-gray-100 border border-gray-100 rounded-lg mb-3">
                <li :for={rol <- @roles_concedidos} class="flex items-center justify-between px-3 py-2 text-sm">
                  <span class="text-gray-800">
                    {rol.nombre}<span :if={rol.es_sistema} class="text-[10px] text-gray-400 ml-1">(sistema)</span>
                  </span>
                  <button type="button" phx-click="quitar_rol_de_usuario" phx-value-rol_id={rol.id}
                    class="text-xs text-red-600 hover:underline">
                    Quitar
                  </button>
                </li>
                <li :if={@roles_concedidos == []} class="px-3 py-4 text-center text-xs text-gray-400">Sin roles todavía.</li>
              </ul>

              <input
                type="text"
                value={@busqueda_rol}
                phx-keyup="buscar_rol"
                phx-debounce="200"
                placeholder="Buscar rol para agregar..."
                class="w-full border border-gray-300 rounded-lg px-3 py-1.5 text-sm text-gray-900 mb-2"
              />
              <ul :if={@busqueda_rol != ""} class="divide-y divide-gray-100 border border-gray-100 rounded-lg">
                <li :for={rol <- @roles_busqueda_resultado} class="flex items-center justify-between px-3 py-2 text-sm">
                  <span class="text-gray-800">
                    {rol.nombre}<span :if={rol.es_sistema} class="text-[10px] text-gray-400 ml-1">(sistema)</span>
                  </span>
                  <button type="button" phx-click="agregar_rol_a_usuario" phx-value-rol_id={rol.id}
                    class="text-xs text-purple-700 hover:underline">
                    Agregar
                  </button>
                </li>
                <li :if={@roles_busqueda_resultado == []} class="px-3 py-4 text-center text-xs text-gray-400">Sin resultados.</li>
              </ul>
            </div>

            <div id="usuario-detalle-panel-bc" class="hidden">
              <p class="text-xs text-gray-400 mb-2">Catálogos que puede leer en {@empresa_en_foco.nombre}, por herencia de sus roles — de solo lectura.</p>
              <ul class="divide-y divide-gray-100 border border-gray-100 rounded-lg">
                <li :for={header <- @bcs_lectura} class="px-3 py-2 text-sm text-gray-800 flex items-center justify-between">
                  <span>{header.schema_context_label}</span>
                  <span class="text-xs text-gray-400 font-mono">{header.schema_context_name}</span>
                </li>
                <li :if={@bcs_lectura == []} class="px-3 py-4 text-center text-xs text-gray-400">Sin catálogos.</li>
              </ul>
            </div>

            <div id="usuario-detalle-panel-alcance" class="hidden">
              <p class="text-xs text-gray-400 mb-3">
                Sucursales, unidades de venta y ubicaciones de almacén que {@usuario_seleccionado.email} puede ver/operar en {@empresa_en_foco.nombre}.
              </p>

              <div :for={nodo <- @jerarquia_alcance} class="mb-3 border border-gray-100 rounded-lg overflow-hidden">
                <div class="flex items-center justify-between px-3 py-2 bg-gray-50">
                  <span class="text-sm font-semibold text-gray-800">{nodo.branch.branch_name}</span>
                  <button
                    type="button"
                    phx-click="toggle_branch_alcance"
                    phx-value-branch_id={nodo.branch.id}
                    phx-value-asignado={to_string(nodo.asignado)}
                    class={[
                      "text-xs font-semibold rounded-lg px-2 py-1 transition-colors",
                      nodo.asignado && "bg-purple-600 text-white",
                      !nodo.asignado && "bg-purple-100 text-purple-700 hover:bg-purple-200"
                    ]}
                  >
                    {if nodo.asignado, do: "✓ Asignado", else: "+ Asignar"}
                  </button>
                </div>

                <div :if={nodo.sales_units != [] or nodo.inventory_locations != []} class="px-3 py-2 grid grid-cols-2 gap-3">
                  <div>
                    <p class="text-[10px] font-semibold text-gray-400 uppercase tracking-wide mb-1">Unidades de venta</p>
                    <div :for={su <- nodo.sales_units} class="flex items-center justify-between py-0.5">
                      <span class="text-xs text-gray-700">{su.sales_unit.sales_unit_name}</span>
                      <button
                        type="button"
                        phx-click="toggle_sales_unit_alcance"
                        phx-value-sales_unit_id={su.sales_unit.id}
                        phx-value-asignado={to_string(su.asignado)}
                        class={[
                          "text-[11px] font-semibold rounded-lg px-2 py-0.5 transition-colors",
                          su.asignado && "bg-purple-600 text-white",
                          !su.asignado && "bg-purple-100 text-purple-700 hover:bg-purple-200"
                        ]}
                      >
                        {if su.asignado, do: "✓", else: "+"}
                      </button>
                    </div>
                    <p :if={nodo.sales_units == []} class="text-xs text-gray-400">—</p>
                  </div>

                  <div>
                    <p class="text-[10px] font-semibold text-gray-400 uppercase tracking-wide mb-1">Ubicaciones de almacén</p>
                    <div :for={il <- nodo.inventory_locations} class="flex items-center justify-between py-0.5">
                      <span class="text-xs text-gray-700">{il.inventory_location.inventory_name}</span>
                      <button
                        type="button"
                        phx-click="toggle_inventory_location_alcance"
                        phx-value-inventory_id={il.inventory_location.id}
                        phx-value-asignado={to_string(il.asignado)}
                        class={[
                          "text-[11px] font-semibold rounded-lg px-2 py-0.5 transition-colors",
                          il.asignado && "bg-purple-600 text-white",
                          !il.asignado && "bg-purple-100 text-purple-700 hover:bg-purple-200"
                        ]}
                      >
                        {if il.asignado, do: "✓", else: "+"}
                      </button>
                    </div>
                    <p :if={nodo.inventory_locations == []} class="text-xs text-gray-400">—</p>
                  </div>
                </div>
              </div>

              <p :if={@jerarquia_alcance == []} class="px-3 py-4 text-center text-xs text-gray-400">
                Esta empresa todavía no tiene sucursales — configurá la jerarquía organizacional primero.
              </p>
            </div>
          <% else %>
            <p class="text-center text-sm text-gray-400 py-24">Elegí un usuario de la izquierda.</p>
          <% end %>
        </div>
      </div>
    </div>
    """
  end
end
