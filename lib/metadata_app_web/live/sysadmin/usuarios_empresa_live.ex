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
    * Sysadmin — UI/permisos-sysadmin (2026-08-16, a pedido explícito): un
      switch por pantalla del menú "Sysadmin" (Roles, Empresas, RBAC
      Usuarios, etc, ver Permissions.capacidades_sysadmin/0) para poder
      dar de alta usuarios que administran RBAC/jerarquía sin ser
      "administrador" completo. No es un mecanismo nuevo -- cada switch
      concede/revoca el rol de sistema dedicado de esa capacidad
      (asignar_rol/revocar_rol tal cual, la misma tabla que ya usa la
      pestaña "Roles" de al lado) -- una forma más cómoda de tildar esos 9
      roles puntuales sin tener que buscarlos por nombre ahí.
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
  on_mount {MetadataAppWeb.Hooks.Autorizacion, {"sysadmin_usuarios", "leer"}}

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
    %{tipo: :pagina, id: "ambientes", label: "Ambientes de Deploy", nav: "/sysadmin/ambientes"},
    %{tipo: :pagina, id: "acciones_externas", label: "Acciones externas", nav: "/sysadmin/acciones-externas"},
    %{tipo: :pagina, id: "jerarquia", label: "Jerarquía organizacional", nav: "/sysadmin/jerarquia"},
  %{tipo: :pagina, id: "panel_control", label: "Panel Control", nav: "/sysadmin/panel-control"}
  ]

  # Forma "vacía" de la pestaña Alcance -- reusada en mount/3 y en cada
  # reset (cambiar de empresa gestionada, cerrar detalle, quitar la
  # empresa en foco al propio usuario). Rediseño 2026-08-13 (arquitectura
  # ERP: Empresa -> N Branch -> N Inventory -> N Sales Unit, Sales Unit
  # opcional) -- a diferencia de la versión anterior (4 listas planas,
  # todas mezclando TODAS las empresas del usuario en una sola lista), la
  # pestaña Alcance ahora es GLOBAL al usuario (no depende de qué empresa
  # está "en foco" en esta pantalla) y anidada: `por_empresa` es
  # `%{empresa_id => %{branches_asignadas: [%{branch:, inventories_...,
  # sales_units_..., inventory_default_id, sales_unit_default_id}, ...],
  # branches_disponibles:, branch_default_id:}}`.
  @alcance_vacio %{
    empresas: [],
    empresas_disponibles: [],
    empresa_default_id: nil,
    por_empresa: %{}
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
     |> assign(:bcs_lectura, [])
     |> assign(:capacidades_sysadmin, Permissions.capacidades_sysadmin())
     |> assign(:capacidades_sysadmin_roles, Permissions.roles_de_capacidades_sysadmin())
     |> assign(:capacidades_sysadmin_concedidas, MapSet.new())
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
         bcs_lectura: [],
         capacidades_sysadmin_concedidas: MapSet.new(),
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
       bcs_lectura: [],
       capacidades_sysadmin_concedidas: MapSet.new(),
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

  # Switch de la pestaña "Sysadmin" -- concede/revoca el rol de sistema
  # dedicado de esa capacidad puntual, ni más ni menos que lo que ya hacen
  # agregar_rol_a_usuario/quitar_rol_de_usuario de la pestaña "Roles" de al
  # lado (misma tabla, mismas funciones). Si la migración de seed no corrió
  # todavía, la capacidad no tiene rol resuelto en @capacidades_sysadmin_roles
  # y el click no hace nada -- no hay nada que togglear.
  def handle_event("toggle_capacidad_sysadmin", %{"recurso" => recurso}, socket) do
    %{usuario_seleccionado: usuario, empresa_en_foco: empresa, capacidades_sysadmin_roles: roles_por_recurso} = socket.assigns

    case Map.get(roles_por_recurso, recurso) do
      nil ->
        {:noreply, socket}

      rol ->
        if MapSet.member?(socket.assigns.capacidades_sysadmin_concedidas, recurso) do
          Permissions.revocar_rol(usuario.id, rol.id, empresa.id)
        else
          Permissions.asignar_rol(usuario.id, rol.id, empresa.id)
        end

        {:noreply, cargar_detalle_usuario(socket)}
    end
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
         bcs_lectura: [],
         capacidades_sysadmin_concedidas: MapSet.new(),
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

  # Default (2026-08-13, rediseño ERP) -- 3 handlers gemelos, mismo
  # criterio de "toggle" que los de arriba: si YA es el default, el
  # click lo limpia (nil); si no, lo fija (reemplaza cualquier default
  # previo de esa misma dimensión sin acción aparte, el campo es un id
  # único, no una lista). Solo tiene sentido sobre un renglón ya
  # asignado -- el botón de "Default" ni se muestra en el render si no
  # lo está (ver .seccion_alcance/1, `:if={@evento_default}` sobre
  # `asignados`). branch_default es por empresa (empresa_id llega como
  # phx-value); inventory/sales_unit default son por SUCURSAL puntual
  # (branch_id Y empresa_id llegan como phx-value -- empresa_id hace
  # falta para resolver es_administrador?, ver .seccion_alcance/1).
  def handle_event("toggle_branch_default", %{"id" => id, "empresa_id" => empresa_id, "default" => default}, socket) do
    usuario = socket.assigns.usuario_seleccionado
    empresa_id = String.to_integer(empresa_id)
    es_administrador? = Permissions.administrador?(usuario.id, empresa_id)
    nuevo_id = if default == "true", do: nil, else: String.to_integer(id)

    Autenticacion.definir_branch_default(usuario.id, empresa_id, nuevo_id, es_administrador?)
    {:noreply, cargar_detalle_usuario(socket)}
  end

  def handle_event("toggle_inventory_default", %{"id" => id, "branch_id" => branch_id, "empresa_id" => empresa_id, "default" => default}, socket) do
    usuario = socket.assigns.usuario_seleccionado
    branch_id = String.to_integer(branch_id)
    es_administrador? = Permissions.administrador?(usuario.id, String.to_integer(empresa_id))
    nuevo_id = if default == "true", do: nil, else: String.to_integer(id)

    Autenticacion.definir_inventory_default_de_branch(usuario.id, branch_id, nuevo_id, es_administrador?)
    {:noreply, cargar_detalle_usuario(socket)}
  end

  def handle_event("toggle_sales_unit_default", %{"id" => id, "branch_id" => branch_id, "empresa_id" => empresa_id, "default" => default}, socket) do
    usuario = socket.assigns.usuario_seleccionado
    branch_id = String.to_integer(branch_id)
    es_administrador? = Permissions.administrador?(usuario.id, String.to_integer(empresa_id))
    nuevo_id = if default == "true", do: nil, else: String.to_integer(id)

    Autenticacion.definir_sales_unit_default_de_branch(usuario.id, branch_id, nuevo_id, es_administrador?)
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
    %{usuario_seleccionado: usuario, empresa_en_foco: empresa, capacidades_sysadmin_roles: roles_por_recurso} = socket.assigns

    roles_concedidos = Permissions.roles_de_usuario(usuario.id, empresa.id)
    rol_ids_concedidos = MapSet.new(roles_concedidos, & &1.id)

    capacidades_sysadmin_concedidas =
      for {recurso, rol} <- roles_por_recurso, MapSet.member?(rol_ids_concedidos, rol.id), into: MapSet.new(), do: recurso

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
    |> assign(:bcs_lectura, bcs_lectura)
    |> assign(:capacidades_sysadmin_concedidas, capacidades_sysadmin_concedidas)
    |> assign(:alcance, cargar_alcance(usuario))
    |> assign(:alias_form, to_form(Autenticacion.change_usuario_alias(usuario)))
  end

  # Alcance del usuario, ANIDADO por empresa (rediseño 2026-08-13,
  # arquitectura ERP: Empresa -> N Branch -> N Inventory -> N Sales Unit,
  # Sales Unit opcional -- mockup del usuario, confirmado explícito).
  # Reemplaza las 4 listas planas del rediseño anterior (2026-08-12, que
  # mezclaban TODAS las empresas del usuario en una sola lista de
  # sucursales/almacenes) -- ahora es GLOBAL al usuario, no depende de
  # `empresa_en_foco`: un admin ve/edita la jerarquía completa del
  # usuario en TODAS sus empresas desde esta misma pestaña, no solo la
  # que está gestionando en Roles/BC. Se arma desde 0 en cada carga --
  # son listas chicas (decenas, no miles) y así se evita cualquier
  # desincronización con lo que Autenticacion ya reporta como fuente de
  # verdad.
  defp cargar_alcance(usuario) do
    empresas_del_usuario = Autenticacion.empresas_de_usuario(usuario.id)
    empresas_del_usuario_ids = MapSet.new(empresas_del_usuario, & &1.id)
    empresas_disponibles = Enum.reject(Autenticacion.listar_empresas(), &MapSet.member?(empresas_del_usuario_ids, &1.id))
    empresa_default = Autenticacion.empresa_default_de_usuario(usuario.id)

    %{
      empresas: empresas_del_usuario,
      empresas_disponibles: empresas_disponibles,
      empresa_default_id: empresa_default && empresa_default.id,
      por_empresa: Map.new(empresas_del_usuario, &{&1.id, cargar_alcance_de_empresa(usuario, &1)})
    }
  end

  defp cargar_alcance_de_empresa(usuario, empresa) do
    branch_ids_asignados = usuario.id |> Autenticacion.branches_de_usuario(empresa.id) |> Enum.map(& &1.id) |> MapSet.new()
    todas_branches = Autenticacion.listar_branches(empresa.id)
    {branches_asignadas, branches_disponibles} = Enum.split_with(todas_branches, &MapSet.member?(branch_ids_asignados, &1.id))
    branch_default = Autenticacion.branch_default_de_usuario(usuario.id, empresa.id)

    %{
      branches_asignadas: Enum.map(branches_asignadas, &cargar_alcance_de_branch(usuario, empresa, &1)),
      branches_disponibles: branches_disponibles,
      branch_default_id: branch_default && branch_default.id
    }
  end

  # Almacén/Unidad de venta acotados a ESTA sucursal puntual (un almacén
  # pertenece a UNA sola branch, nunca se mezclan entre sucursales -- ver
  # UsuarioBranch, donde ahora vive el default de cada una).
  defp cargar_alcance_de_branch(usuario, empresa, branch) do
    inventory_ids_asignados = usuario.id |> Autenticacion.inventory_locations_de_usuario(empresa.id) |> Enum.map(& &1.id) |> MapSet.new()
    todas_inventories = Autenticacion.listar_inventory_locations(branch.id)
    {inventories_asignadas, inventories_disponibles} = Enum.split_with(todas_inventories, &MapSet.member?(inventory_ids_asignados, &1.id))

    sales_unit_ids_asignados = usuario.id |> Autenticacion.sales_units_de_usuario(empresa.id) |> Enum.map(& &1.id) |> MapSet.new()
    todas_sales_units = Autenticacion.listar_sales_units(branch.id)
    {sales_units_asignadas, sales_units_disponibles} = Enum.split_with(todas_sales_units, &MapSet.member?(sales_unit_ids_asignados, &1.id))

    defaults = Autenticacion.defaults_de_branch(usuario.id, branch.id)

    %{
      branch: branch,
      inventories_asignadas: inventories_asignadas,
      inventories_disponibles: inventories_disponibles,
      inventory_default_id: defaults.inventory_location && defaults.inventory_location.id,
      sales_units_asignadas: sales_units_asignadas,
      sales_units_disponibles: sales_units_disponibles,
      sales_unit_default_id: defaults.sales_unit && defaults.sales_unit.id
    }
  end

  defp usuarios_filtrados(usuarios, ""), do: usuarios

  defp usuarios_filtrados(usuarios, busqueda) do
    texto = String.downcase(busqueda)
    Enum.filter(usuarios, &String.contains?(String.downcase(&1.email), texto))
  end

  # Celda de tabla para Almacén/Unidad de venta (rediseño 2026-08-13, a
  # pedido explícito -- "respeta mi bosquejo": tabla Empresa | Sucursal |
  # Almacén | Unidad de venta, un ● verde marca el default, en vez de las
  # cards apiladas con "★ Default" de la versión anterior. Lista chica +
  # form de agregar, todo compacto para caber en una celda.
  attr :asignados, :list, required: true
  attr :disponibles, :list, required: true
  attr :nombre_campo, :atom, required: true, doc: ":inventory_name o :sales_unit_name"
  attr :evento_agregar, :string, required: true
  attr :evento_quitar, :string, required: true
  attr :evento_default, :string, required: true
  attr :default_id, :any, default: nil
  attr :empresa_id, :any, required: true, doc: "phx-value en el botón Default -- resuelve es_administrador?"
  attr :branch_id, :any, required: true, doc: "phx-value en el botón Default -- definir_*_default_de_branch/4"

  defp celda_lista(assigns) do
    ~H"""
    <div class="min-w-[140px]">
      <ul class="space-y-0.5 mb-1">
        <li :for={item <- @asignados} class="flex items-center gap-1.5 text-xs">
          <button
            type="button"
            phx-click={@evento_default}
            phx-value-id={item.id}
            phx-value-default={to_string(item.id == @default_id)}
            phx-value-empresa_id={@empresa_id}
            phx-value-branch_id={@branch_id}
            title={if item.id == @default_id, do: "Default", else: "Marcar como default"}
            class={[
              "w-1.5 h-1.5 rounded-full shrink-0",
              item.id == @default_id && "bg-green-500",
              item.id != @default_id && "bg-gray-300 hover:bg-gray-400"
            ]}
          >
          </button>
          <span class="text-gray-800 truncate">{Map.fetch!(item, @nombre_campo)}</span>
          <button
            type="button"
            phx-click={@evento_quitar}
            phx-value-id={item.id}
            class="text-gray-300 hover:text-red-500 ml-auto shrink-0"
            title="Quitar"
          >
            ✕
          </button>
        </li>
        <li :if={@asignados == []} class="text-xs text-gray-300">—</li>
      </ul>
      <form phx-submit={@evento_agregar} class="flex gap-1">
        <select name="id" required class="flex-1 min-w-0 border border-gray-200 rounded px-1 py-0.5 text-[11px] text-gray-700">
          <option value="">— Agregar —</option>
          <option :for={item <- @disponibles} value={item.id}>{Map.fetch!(item, @nombre_campo)}</option>
        </select>
        <button type="submit" class="text-[11px] text-purple-700 font-semibold hover:underline shrink-0">+</button>
      </form>
    </div>
    """
  end

  # Switch visual (no daisyUI "toggle" -- mismo motivo que
  # ConfiguracionCuentaModal, colores explícitos para que se vea igual sin
  # importar el theme de la página) -- track + thumb con Tailwind puro,
  # phx-click en el <button> completo, sin <input> ni <form> de por medio.
  attr :recurso, :string, required: true
  attr :etiqueta, :string, required: true
  attr :prendido?, :boolean, required: true
  attr :resuelto?, :boolean, required: true, doc: "false si la migración de seed no corrió -- sin rol que togglear"

  defp switch_capacidad(assigns) do
    ~H"""
    <div class="flex items-center justify-between px-3 py-2.5 border border-gray-100 rounded-lg">
      <span class="text-sm text-gray-800">{@etiqueta}</span>
      <button
        type="button"
        role="switch"
        aria-checked={to_string(@prendido?)}
        disabled={!@resuelto?}
        phx-click={@resuelto? && "toggle_capacidad_sysadmin"}
        phx-value-recurso={@recurso}
        title={if @resuelto?, do: nil, else: "Corré la migración de seed para habilitar este switch"}
        class={[
          "relative inline-flex h-5 w-9 items-center rounded-full transition-colors shrink-0",
          @prendido? && "bg-purple-600",
          !@prendido? && "bg-gray-300",
          !@resuelto? && "opacity-40 cursor-not-allowed"
        ]}
      >
        <span class={[
          "inline-block h-3.5 w-3.5 transform rounded-full bg-white transition-transform",
          @prendido? && "translate-x-[18px]",
          !@prendido? && "translate-x-[3px]"
        ]}>
        </span>
      </button>
    </div>
    """
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
              %{key: "roles", label: "Roles"},
              %{key: "sysadmin", label: "Sysadmin"},
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

            <div id="usuario-detalle-panel-sysadmin" class="hidden">
              <p class="text-xs text-gray-400 mb-2">
                Acceso a cada pantalla del menú "Sysadmin" en {@empresa_en_foco.nombre} -- independiente de "administrador" (que ya ve todo).
              </p>
              <div class="space-y-1.5">
                <.switch_capacidad
                  :for={{recurso, _rol_nombre, etiqueta} <- @capacidades_sysadmin}
                  recurso={recurso}
                  etiqueta={etiqueta}
                  prendido?={MapSet.member?(@capacidades_sysadmin_concedidas, recurso)}
                  resuelto?={Map.has_key?(@capacidades_sysadmin_roles, recurso)}
                />
              </div>
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

            <div id="usuario-detalle-panel-alcance" class="hidden space-y-4">
              <p class="text-xs text-gray-400">
                Unidad Operativa de {@usuario_seleccionado.email} — el ● verde marca el default (lo que el login elige solo). Empresa, Sucursal y Almacén de cada default son OBLIGATORIOS: sin completarlos, no puede crear registros en catálogos con Alcance de Datos.
              </p>

              <!-- Empresa: raíz del árbol, arriba de la tabla -- las otras 3
                   columnas dependen de a qué empresa pertenecen (Sucursal
                   de una empresa, Almacén/Unidad de venta de una sucursal). -->
              <div class="border border-gray-200 rounded-lg p-3">
                <h3 class="text-xs font-bold text-gray-700 uppercase tracking-wide mb-2">Empresa</h3>
                <ul class="space-y-1 mb-2">
                  <li :for={empresa <- @alcance.empresas} class="flex items-center gap-2 text-sm">
                    <button
                      type="button"
                      phx-click="toggle_empresa_default"
                      phx-value-id={empresa.id}
                      phx-value-default={to_string(empresa.id == @alcance.empresa_default_id)}
                      title={if empresa.id == @alcance.empresa_default_id, do: "Default -- el login la elige sola", else: "Marcar como default"}
                      class={[
                        "w-2.5 h-2.5 rounded-full shrink-0",
                        empresa.id == @alcance.empresa_default_id && "bg-green-500",
                        empresa.id != @alcance.empresa_default_id && "bg-gray-300 hover:bg-gray-400"
                      ]}
                    >
                    </button>
                    <span class="text-gray-800">{empresa.nombre}</span>
                    <span :if={empresa.id == @current_scope.empresa_activa.id} class="text-[10px] text-purple-600 font-semibold">(activa)</span>
                    <button
                      type="button"
                      phx-click="quitar_empresa_de_usuario"
                      phx-value-id={empresa.id}
                      data-confirm={"¿Quitar a #{@usuario_seleccionado.email} de #{empresa.nombre}? Pierde cualquier rol que tenga ahí."}
                      class="text-gray-300 hover:text-red-500 ml-auto text-xs shrink-0"
                      title="Quitar"
                    >
                      ✕
                    </button>
                  </li>
                  <li :if={@alcance.empresas == []} class="text-xs text-gray-400">Sin empresas.</li>
                </ul>
                <form phx-submit="agregar_empresa_a_usuario" class="flex gap-2">
                  <select name="id" required class="flex-1 border border-gray-300 rounded-lg px-2 py-1 text-xs text-gray-900">
                    <option value="">— Elegir empresa —</option>
                    <option :for={empresa <- @alcance.empresas_disponibles} value={empresa.id}>{empresa.nombre}</option>
                  </select>
                  <button type="submit" class="px-2 py-1 rounded-lg bg-purple-600 text-white text-xs font-semibold hover:bg-purple-700 whitespace-nowrap">
                    Agregar
                  </button>
                </form>
              </div>

              <!-- Empresa -> Sucursal -> Almacén -> Unidad de venta, en 4
                   columnas (bosquejo del usuario) -- una fila por
                   sucursal, Empresa agrupada con rowspan. -->
              <div class="overflow-x-auto rounded-lg border border-gray-200">
                <table class="min-w-full divide-y divide-gray-200 text-sm">
                  <thead class="bg-gray-50">
                    <tr>
                      <th class="px-3 py-2 text-left text-[11px] font-bold text-gray-500 uppercase tracking-wide">Empresa</th>
                      <th class="px-3 py-2 text-left text-[11px] font-bold text-gray-500 uppercase tracking-wide">Sucursal</th>
                      <th class="px-3 py-2 text-left text-[11px] font-bold text-gray-500 uppercase tracking-wide">Almacén</th>
                      <th class="px-3 py-2 text-left text-[11px] font-bold text-gray-500 uppercase tracking-wide">Unidad de venta</th>
                    </tr>
                  </thead>
                  <tbody class="divide-y divide-gray-100">
                    <%= for empresa <- @alcance.empresas do %>
                      <% info_empresa = @alcance.por_empresa[empresa.id] %>
                      <% filas = if info_empresa.branches_asignadas == [], do: [nil], else: info_empresa.branches_asignadas %>
                      <%= for {info_branch, idx} <- Enum.with_index(filas) do %>
                        <tr class="align-top">
                          <td :if={idx == 0} rowspan={length(filas) + 1} class="px-3 py-2 border-r border-gray-100 align-top bg-gray-50/50">
                            <span class="font-semibold text-gray-900">{empresa.nombre}</span>
                            <span :if={empresa.id == @alcance.empresa_default_id} class="block text-[10px] text-green-600 font-semibold mt-0.5">● default</span>
                            <span
                              :if={info_empresa.branches_asignadas != [] and is_nil(info_empresa.branch_default_id)}
                              class="block text-[10px] text-red-600 font-semibold mt-0.5"
                            >
                              ⚠ falta default
                            </span>
                          </td>
                          <%= if info_branch do %>
                            <td class="px-3 py-2 border-r border-gray-100">
                              <div class="flex items-center gap-1.5">
                                <button
                                  type="button"
                                  phx-click="toggle_branch_default"
                                  phx-value-id={info_branch.branch.id}
                                  phx-value-default={to_string(info_branch.branch.id == info_empresa.branch_default_id)}
                                  phx-value-empresa_id={empresa.id}
                                  title={if info_branch.branch.id == info_empresa.branch_default_id, do: "Default", else: "Marcar como default"}
                                  class={[
                                    "w-2 h-2 rounded-full shrink-0",
                                    info_branch.branch.id == info_empresa.branch_default_id && "bg-green-500",
                                    info_branch.branch.id != info_empresa.branch_default_id && "bg-gray-300 hover:bg-gray-400"
                                  ]}
                                >
                                </button>
                                <span class="text-gray-800">{info_branch.branch.branch_name}</span>
                                <button
                                  type="button"
                                  phx-click="quitar_branch_de_usuario"
                                  phx-value-id={info_branch.branch.id}
                                  class="text-gray-300 hover:text-red-500 ml-auto text-xs shrink-0"
                                  title="Quitar"
                                >
                                  ✕
                                </button>
                              </div>
                            </td>
                            <td class="px-3 py-2 border-r border-gray-100">
                              <.celda_lista
                                asignados={info_branch.inventories_asignadas}
                                disponibles={info_branch.inventories_disponibles}
                                nombre_campo={:inventory_name}
                                evento_agregar="agregar_inventory_location_a_usuario"
                                evento_quitar="quitar_inventory_location_de_usuario"
                                evento_default="toggle_inventory_default"
                                default_id={info_branch.inventory_default_id}
                                empresa_id={empresa.id}
                                branch_id={info_branch.branch.id}
                              />
                            </td>
                            <td class="px-3 py-2">
                              <.celda_lista
                                asignados={info_branch.sales_units_asignadas}
                                disponibles={info_branch.sales_units_disponibles}
                                nombre_campo={:sales_unit_name}
                                evento_agregar="agregar_sales_unit_a_usuario"
                                evento_quitar="quitar_sales_unit_de_usuario"
                                evento_default="toggle_sales_unit_default"
                                default_id={info_branch.sales_unit_default_id}
                                empresa_id={empresa.id}
                                branch_id={info_branch.branch.id}
                              />
                            </td>
                          <% else %>
                            <td colspan="3" class="px-3 py-2 text-xs text-gray-300">Sin sucursales todavía.</td>
                          <% end %>
                        </tr>
                      <% end %>
                      <tr>
                        <td colspan="3" class="px-3 py-2">
                          <form phx-submit="agregar_branch_a_usuario" class="flex gap-1.5 max-w-xs">
                            <select name="id" required class="flex-1 min-w-0 border border-gray-200 rounded px-1.5 py-1 text-[11px] text-gray-700">
                              <option value="">— Agregar sucursal —</option>
                              <option :for={branch <- info_empresa.branches_disponibles} value={branch.id}>{branch.branch_name}</option>
                            </select>
                            <button type="submit" class="text-[11px] text-purple-700 font-semibold hover:underline shrink-0">+ Agregar</button>
                          </form>
                        </td>
                      </tr>
                    <% end %>
                    <tr :if={@alcance.empresas == []}>
                      <td colspan="4" class="px-3 py-6 text-center text-xs text-gray-400">Asigná una empresa arriba para configurar su jerarquía.</td>
                    </tr>
                  </tbody>
                </table>
              </div>
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
