defmodule MetadataAppWeb.Sysadmin.UsuariosEmpresaLive do
  @moduledoc """
  Administrador de usuarios: maestro-detalle (rediseño 2026-08-02, a pedido
  explícito con mockup) — lista buscable de usuarios de la empresa activa a
  la izquierda, y a la derecha 3 pestañas para el usuario seleccionado:

    * Generales — alias/email (por ahora solo lectura; "Desactivar cuenta"
      queda para una entrega aparte, ver memoria del proyecto).
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
    * Alcance — Fase 7 del modelo de Alcance de Datos (2026-08-11),
      rediseñada 2026-08-12 a pedido explícito ("estaba desordenado"): 4
      secciones verticales, mismo orden siempre -- Empresa, Sucursales,
      Almacén, Unidades de venta. La pestaña "Empresas" separada de antes
      se plegó acá adentro (era el mismo concepto -- a QUÉ pertenece este
      usuario -- repartido en dos lugares sin necesidad). Cada sección
      tiene el mismo patrón: lista de lo YA asignado (con botón "Quitar" y,
      para las 3 de jerarquía, "☆/★ Default" -- ver Autenticacion.
      resolver_jerarquia_operativa/3, el default hace que el login elija
      esa opción sola aunque haya varias permitidas) + un <select> con lo
      DISPONIBLE (nunca lo ya asignado) y un botón "Agregar". QUÉ
      branches/sales_units/inventory_locations puede VER/OPERAR es la
      asignación N:N de Autenticacion.asignar_branch/2 etc., la que
      hidrata Scope.branches_permitidos/sales_units_permitidas/
      inventory_locations_permitidas -- distinto del "alcance_tipo" por
      rol (eso se configura en CatalogoPermisosLive, es "QUÉ TIPO de
      filtro aplica", no "cuáles ids concretos", ver moduledoc de
      MetadataApp.Autenticacion.Scope).
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

  # Forma "vacía" de la pestaña Alcance -- reusada en mount/3 y en cada
  # reset (cambiar de empresa gestionada, cerrar detalle, quitar la
  # empresa en foco al propio usuario), mismo criterio que ya usaban
  # jerarquia_alcance: [] / empresas_estado: [] antes del rediseño 2026-08-12.
  @alcance_vacio %{
    branches_asignadas: [],
    branches_disponibles: [],
    sales_units_asignadas: [],
    sales_units_disponibles: [],
    inventory_locations_asignadas: [],
    inventory_locations_disponibles: [],
    nombres_branch: %{},
    branch_default_id: nil,
    sales_unit_default_id: nil,
    inventory_default_id: nil
  }

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
     |> assign(:empresa_default_id, nil)
     |> assign(:bcs_lectura, [])
     |> assign(:alcance, @alcance_vacio)
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
         empresa_default_id: nil,
         bcs_lectura: [],
         alcance: @alcance_vacio
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
       empresa_default_id: nil,
       bcs_lectura: [],
       alcance: @alcance_vacio
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

  # Simplificado 2026-08-12 (era un ida y vuelta de 2 eventos --
  # phx-change para "recordar" lo elegido + phx-submit leyendo eso de
  # socket.assigns -- innecesario, phx-submit ya manda el valor del
  # <select> en params). Mismo guard "vacío no hace nada" que el resto de
  # los agregar_*_a_usuario/2 nuevos.
  def handle_event("agregar_empresa_a_usuario", %{"id" => id}, socket) when id not in [nil, ""] do
    Autenticacion.agregar_usuario_a_empresa(socket.assigns.usuario_seleccionado.email, String.to_integer(id))
    {:noreply, socket |> cargar_usuarios() |> cargar_detalle_usuario()}
  end

  def handle_event("agregar_empresa_a_usuario", _params, socket), do: {:noreply, socket}

  # Quitar la empresa EN FOCO (la misma que arma la lista de la izquierda)
  # deja al usuario seleccionado fuera de esa lista — a diferencia de
  # cualquier otra empresa (donde solo se refresca la pestaña Alcance).
  def handle_event("quitar_empresa_de_usuario", %{"id" => id}, socket) do
    %{usuario_seleccionado: usuario, empresa_en_foco: empresa_en_foco} = socket.assigns
    empresa_id = String.to_integer(id)

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
         empresa_default_id: nil,
         bcs_lectura: [],
         alcance: @alcance_vacio
       )
       |> cargar_usuarios()}
    else
      {:noreply, cargar_detalle_usuario(socket)}
    end
  end

  # Fase 7 del modelo de Alcance de Datos, rediseñada 2026-08-12 -- 3
  # pares gemelos agregar/quitar, uno por dimensión de la jerarquía
  # (reemplazan los toggle_*_alcance de antes: la UI nueva es lista +
  # <select> de lo disponible, no un botón por cada fila posible). Los 4
  # pares de esta pantalla (empresa incluida) comparten el mismo param
  # "id" -- HEEx no permite nombres de atributo dinámicos
  # (`phx-value-{@campo}` no es válido), así que .seccion_alcance/1
  # emite siempre `phx-value-id`/`name="id"`; el nombre del EVENTO ya
  # dice de qué dimensión se trata, no hace falta un param distinto por
  # cada una. El guard `when id not in [nil, ""]` en agregar_*/2 es la
  # misma defensa que ya usaba agregar_empresa_a_usuario/2 -- el
  # `<select>` tiene `required`, pero eso es solo del lado del cliente.
  def handle_event("agregar_branch_a_usuario", %{"id" => id}, socket) when id not in [nil, ""] do
    Autenticacion.asignar_branch(socket.assigns.usuario_seleccionado.id, String.to_integer(id))
    {:noreply, cargar_detalle_usuario(socket)}
  end

  def handle_event("agregar_branch_a_usuario", _params, socket), do: {:noreply, socket}

  def handle_event("quitar_branch_de_usuario", %{"id" => id}, socket) do
    Autenticacion.revocar_branch(socket.assigns.usuario_seleccionado.id, String.to_integer(id))
    {:noreply, cargar_detalle_usuario(socket)}
  end

  def handle_event("agregar_sales_unit_a_usuario", %{"id" => id}, socket) when id not in [nil, ""] do
    Autenticacion.asignar_sales_unit(socket.assigns.usuario_seleccionado.id, String.to_integer(id))
    {:noreply, cargar_detalle_usuario(socket)}
  end

  def handle_event("agregar_sales_unit_a_usuario", _params, socket), do: {:noreply, socket}

  def handle_event("quitar_sales_unit_de_usuario", %{"id" => id}, socket) do
    Autenticacion.revocar_sales_unit(socket.assigns.usuario_seleccionado.id, String.to_integer(id))
    {:noreply, cargar_detalle_usuario(socket)}
  end

  def handle_event("agregar_inventory_location_a_usuario", %{"id" => id}, socket) when id not in [nil, ""] do
    Autenticacion.asignar_inventory_location(socket.assigns.usuario_seleccionado.id, String.to_integer(id))
    {:noreply, cargar_detalle_usuario(socket)}
  end

  def handle_event("agregar_inventory_location_a_usuario", _params, socket), do: {:noreply, socket}

  def handle_event("quitar_inventory_location_de_usuario", %{"id" => id}, socket) do
    Autenticacion.revocar_inventory_location(socket.assigns.usuario_seleccionado.id, String.to_integer(id))
    {:noreply, cargar_detalle_usuario(socket)}
  end

  # Default (2026-08-12) -- 3 handlers gemelos, mismo criterio de
  # "toggle" que los de arriba: si YA es el default, el click lo limpia
  # (nil); si no, lo fija (reemplaza cualquier default previo de esa
  # misma dimensión sin acción aparte, el campo es un id único, no una
  # lista). Solo tiene sentido sobre un renglón ya asignado -- el botón
  # de "Default" ni se muestra en el render si no lo está (ver
  # .seccion_alcance/1, `:if={@evento_default}` sobre `asignados`).
  def handle_event("toggle_branch_default", %{"id" => id, "default" => default}, socket) do
    %{usuario_seleccionado: usuario, empresa_en_foco: empresa} = socket.assigns
    es_administrador? = Permissions.administrador?(usuario.id, empresa.id)
    nuevo_id = if default == "true", do: nil, else: String.to_integer(id)

    Autenticacion.definir_branch_default(usuario.id, empresa.id, nuevo_id, es_administrador?)
    {:noreply, cargar_detalle_usuario(socket)}
  end

  def handle_event("toggle_sales_unit_default", %{"id" => id, "default" => default}, socket) do
    %{usuario_seleccionado: usuario, empresa_en_foco: empresa} = socket.assigns
    es_administrador? = Permissions.administrador?(usuario.id, empresa.id)
    nuevo_id = if default == "true", do: nil, else: String.to_integer(id)

    Autenticacion.definir_sales_unit_default(usuario.id, empresa.id, nuevo_id, es_administrador?)
    {:noreply, cargar_detalle_usuario(socket)}
  end

  def handle_event("toggle_inventory_location_default", %{"id" => id, "default" => default}, socket) do
    %{usuario_seleccionado: usuario, empresa_en_foco: empresa} = socket.assigns
    es_administrador? = Permissions.administrador?(usuario.id, empresa.id)
    nuevo_id = if default == "true", do: nil, else: String.to_integer(id)

    Autenticacion.definir_inventory_location_default(usuario.id, empresa.id, nuevo_id, es_administrador?)
    {:noreply, cargar_detalle_usuario(socket)}
  end

  # Empresa default (2026-08-12) -- mismo criterio de "toggle" que los 3 de
  # arriba, pero vive en Usuario (cross-empresa) en vez de UsuarioEmpresa,
  # por eso llama a Autenticacion.definir_empresa_default/2 (sin
  # es_administrador?, no aplica: no hay bypass de "todas las empresas",
  # solo puede marcar default una a la que ya pertenece).
  def handle_event("toggle_empresa_default", %{"id" => id, "default" => default}, socket) do
    usuario = socket.assigns.usuario_seleccionado
    nuevo_id = if default == "true", do: nil, else: String.to_integer(id)

    Autenticacion.definir_empresa_default(usuario.id, nuevo_id)
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

    empresa_default = Autenticacion.empresa_default_de_usuario(usuario.id)

    socket
    |> assign(:roles_concedidos, roles_concedidos)
    |> assign(:busqueda_rol, "")
    |> assign(:roles_busqueda_resultado, [])
    |> assign(:empresas_estado, empresas_del_usuario)
    |> assign(:empresas_disponibles, empresas_disponibles)
    |> assign(:empresa_default_id, empresa_default && empresa_default.id)
    |> assign(:bcs_lectura, bcs_lectura)
    |> assign(:alcance, cargar_alcance(usuario, empresa))
    |> assign(:alias_form, to_form(Autenticacion.change_usuario_alias(usuario)))
  end

  # Listas PLANAS (asignada/disponible) de las 3 dimensiones de la
  # jerarquía en la empresa en foco -- reemplaza el árbol Branch ->
  # {SalesUnit, InventoryLocation} de antes (rediseño 2026-08-12, a
  # pedido explícito: "estaba desordenado", 4 secciones verticales en vez
  # de un árbol anidado). Sales units/inventory locations llevan su
  # branch_id tal cual (structs reales, no un mapa envolvente) -- el
  # nombre de sucursal para mostrar junto a cada una sale de
  # nombres_branch, resuelto una sola vez acá. Se arma desde 0 en cada
  # carga -- son listas chicas (decenas, no miles, por empresa) y así se
  # evita cualquier desincronización con lo que Autenticacion.
  # alcance_de_usuario/2 y defaults_de_usuario/2 ya reportan como fuente
  # de verdad.
  defp cargar_alcance(usuario, empresa) do
    %{
      branches_permitidos: branch_ids,
      sales_units_permitidas: sales_unit_ids,
      inventory_locations_permitidas: inventory_ids
    } = Autenticacion.alcance_de_usuario(usuario.id, empresa.id)

    defaults = Autenticacion.defaults_de_usuario(usuario.id, empresa.id)

    branch_ids = MapSet.new(branch_ids)
    sales_unit_ids = MapSet.new(sales_unit_ids)
    inventory_ids = MapSet.new(inventory_ids)

    todas_branches = Autenticacion.listar_branches(empresa.id)
    todas_sales_units = Autenticacion.listar_sales_units_de_empresa(empresa.id)
    todas_inventory_locations = Autenticacion.listar_inventory_locations_de_empresa(empresa.id)

    {branches_asignadas, branches_disponibles} = Enum.split_with(todas_branches, &MapSet.member?(branch_ids, &1.id))
    {sales_units_asignadas, sales_units_disponibles} = Enum.split_with(todas_sales_units, &MapSet.member?(sales_unit_ids, &1.id))

    {inventory_locations_asignadas, inventory_locations_disponibles} =
      Enum.split_with(todas_inventory_locations, &MapSet.member?(inventory_ids, &1.id))

    %{
      branches_asignadas: branches_asignadas,
      branches_disponibles: branches_disponibles,
      sales_units_asignadas: sales_units_asignadas,
      sales_units_disponibles: sales_units_disponibles,
      inventory_locations_asignadas: inventory_locations_asignadas,
      inventory_locations_disponibles: inventory_locations_disponibles,
      nombres_branch: Map.new(todas_branches, &{&1.id, &1.branch_name}),
      branch_default_id: defaults.branch && defaults.branch.id,
      sales_unit_default_id: defaults.sales_unit && defaults.sales_unit.id,
      inventory_default_id: defaults.inventory_location && defaults.inventory_location.id
    }
  end

  defp usuarios_filtrados(usuarios, ""), do: usuarios

  defp usuarios_filtrados(usuarios, busqueda) do
    texto = String.downcase(busqueda)
    Enum.filter(usuarios, &String.contains?(String.downcase(&1.email), texto))
  end

  # Pestaña Alcance, rediseñada 2026-08-12 a pedido explícito ("estaba
  # desordenado") -- las 4 secciones (Empresa/Sucursales/Almacén/Unidades
  # de venta) comparten EXACTAMENTE el mismo patrón visual (lista de lo
  # asignado + Quitar, <select> de lo disponible + Agregar), así que es
  # una sola función de componente en vez de repetir el HEEx 4 veces.
  # `nombre_id`/`campo_id_quitar`/`campo_id_default` NO existen como attrs
  # -- HEEx no permite nombres de atributo dinámicos
  # (`phx-value-{@campo}=...` es inválido), así que este componente
  # siempre emite `phx-value-id`/`name="id"`; el nombre del EVENTO
  # (`evento_agregar`/`evento_quitar`/`evento_default`, esos SÍ son
  # dinámicos porque son VALORES de atributo, no nombres) ya dice de qué
  # dimensión se trata.
  attr :titulo, :string, required: true
  attr :asignados, :list, required: true
  attr :disponibles, :list, required: true
  attr :nombre_campo, :atom, required: true, doc: "campo del struct a mostrar como nombre -- :nombre, :branch_name, :inventory_name, :sales_unit_name"
  attr :evento_agregar, :string, required: true
  attr :evento_quitar, :string, required: true
  attr :placeholder_select, :string, required: true
  attr :placeholder_vacio, :string, required: true
  attr :confirmar_quitar, :any, default: nil, doc: "fn(item) -> string | nil -- data-confirm del botón Quitar"
  attr :etiqueta_extra, :any, default: nil, doc: "fn(item) -> string | nil -- ej. \"(activa)\" en Empresa"
  attr :evento_default, :string, default: nil, doc: "nil = esta dimensión no tiene Default (Empresa)"
  attr :default_id, :any, default: nil
  attr :nombres_branch, :map, default: %{}, doc: "id de branch => nombre, para mostrar entre paréntesis en Almacén/Unidades de venta"

  defp seccion_alcance(assigns) do
    ~H"""
    <div>
      <h3 class="text-xs font-bold text-gray-700 uppercase tracking-wide mb-2">{@titulo}</h3>
      <ul class="divide-y divide-gray-100 border border-gray-100 rounded-lg mb-2">
        <li :for={item <- @asignados} class="flex items-center justify-between px-3 py-2 text-sm gap-2">
          <span class="text-gray-800 truncate">
            {Map.fetch!(item, @nombre_campo)}
            <span :if={nombre_sucursal(item, @nombres_branch)} class="text-[10px] text-gray-400 ml-1">({nombre_sucursal(item, @nombres_branch)})</span>
            <span :if={@etiqueta_extra && @etiqueta_extra.(item)} class="text-[10px] text-purple-600 font-semibold ml-1">{@etiqueta_extra.(item)}</span>
          </span>
          <div class="flex items-center gap-2 shrink-0">
            <button
              :if={@evento_default}
              type="button"
              phx-click={@evento_default}
              phx-value-id={item.id}
              phx-value-default={to_string(item.id == @default_id)}
              title={if item.id == @default_id, do: "Default -- el login la elige sola", else: "Marcar como default para el login"}
              class={[
                "text-xs font-semibold rounded-lg px-2 py-1 transition-colors whitespace-nowrap",
                item.id == @default_id && "bg-amber-500 text-white",
                item.id != @default_id && "bg-amber-50 text-amber-700 hover:bg-amber-100"
              ]}
            >
              {if item.id == @default_id, do: "★ Default", else: "☆ Default"}
            </button>
            <button
              type="button"
              phx-click={@evento_quitar}
              phx-value-id={item.id}
              data-confirm={@confirmar_quitar && @confirmar_quitar.(item)}
              class="text-xs text-red-600 hover:underline whitespace-nowrap"
            >
              Quitar
            </button>
          </div>
        </li>
        <li :if={@asignados == []} class="px-3 py-4 text-center text-xs text-gray-400">{@placeholder_vacio}</li>
      </ul>

      <form phx-submit={@evento_agregar} class="flex gap-2">
        <select name="id" required class="flex-1 border border-gray-300 rounded-lg px-2 py-1.5 text-sm text-gray-900">
          <option value="">{@placeholder_select}</option>
          <option :for={item <- @disponibles} value={item.id}>
            {Map.fetch!(item, @nombre_campo)}{if nombre_sucursal(item, @nombres_branch), do: " (#{nombre_sucursal(item, @nombres_branch)})"}
          </option>
        </select>
        <button type="submit" class="px-3 py-1.5 rounded-lg bg-purple-600 text-white text-xs font-semibold hover:bg-purple-700 whitespace-nowrap">
          Agregar
        </button>
      </form>
    </div>
    """
  end

  defp nombre_sucursal(%{branch_id: branch_id}, nombres_branch) when is_map_key(nombres_branch, branch_id),
    do: Map.fetch!(nombres_branch, branch_id)

  defp nombre_sucursal(_item, _nombres_branch), do: nil

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

            <div id="usuario-detalle-panel-alcance" class="hidden space-y-5">
              <p class="text-xs text-gray-400">
                Qué puede ver/operar {@usuario_seleccionado.email} — el ★ marca cuál elige el login solo cuando hay varias asignadas (ver banda de pie).
              </p>

              <.seccion_alcance
                titulo="Empresa"
                asignados={@empresas_estado}
                disponibles={@empresas_disponibles}
                nombre_campo={:nombre}
                evento_agregar="agregar_empresa_a_usuario"
                evento_quitar="quitar_empresa_de_usuario"
                placeholder_select="— Elegir empresa —"
                placeholder_vacio="Sin empresas."
                confirmar_quitar={fn empresa -> "¿Quitar a #{@usuario_seleccionado.email} de #{empresa.nombre}? Pierde cualquier rol que tenga ahí." end}
                etiqueta_extra={fn empresa -> if empresa.id == @current_scope.empresa_activa.id, do: "(activa)" end}
                default_id={@empresa_default_id}
                evento_default="toggle_empresa_default"
              />

              <.seccion_alcance
                titulo="Sucursales"
                asignados={@alcance.branches_asignadas}
                disponibles={@alcance.branches_disponibles}
                nombre_campo={:branch_name}
                evento_agregar="agregar_branch_a_usuario"
                evento_quitar="quitar_branch_de_usuario"
                placeholder_select="— Elegir sucursal —"
                placeholder_vacio="Sin sucursales asignadas."
                default_id={@alcance.branch_default_id}
                evento_default="toggle_branch_default"
              />

              <.seccion_alcance
                titulo="Almacén"
                asignados={@alcance.inventory_locations_asignadas}
                disponibles={@alcance.inventory_locations_disponibles}
                nombre_campo={:inventory_name}
                evento_agregar="agregar_inventory_location_a_usuario"
                evento_quitar="quitar_inventory_location_de_usuario"
                placeholder_select="— Elegir almacén —"
                placeholder_vacio="Sin almacenes asignados."
                default_id={@alcance.inventory_default_id}
                evento_default="toggle_inventory_location_default"
                nombres_branch={@alcance.nombres_branch}
              />

              <.seccion_alcance
                titulo="Unidades de venta"
                asignados={@alcance.sales_units_asignadas}
                disponibles={@alcance.sales_units_disponibles}
                nombre_campo={:sales_unit_name}
                evento_agregar="agregar_sales_unit_a_usuario"
                evento_quitar="quitar_sales_unit_de_usuario"
                placeholder_select="— Elegir unidad de venta —"
                placeholder_vacio="Sin unidades de venta asignadas."
                default_id={@alcance.sales_unit_default_id}
                evento_default="toggle_sales_unit_default"
                nombres_branch={@alcance.nombres_branch}
              />
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
