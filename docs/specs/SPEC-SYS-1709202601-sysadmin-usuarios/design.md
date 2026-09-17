# SPEC-SYS-1709202601 — Sysadmin / Administrador de usuarios

**Documento:** Design · **Fase:** ✅ aprobada (2026-09-17). **§10 y §4
agregadas/reescritas el mismo día** — dos incrementos reales completos
(eliminación total de usuario R13a-e; picker de doble lista para Roles
R14-R16c), ver `tasks.md` para el detalle de ejecución y verificación.

Documentación retroactiva — describe el mecanismo tal como existe en
`lib/metadata_app_web/live/sysadmin/usuarios_empresa_live.ex` (un solo
LiveView, sin `live_component`s propios aparte de los dos function
components privados `celda_lista/1` y `switch_capacidad/1`).

## 1. Gate de acceso y menú fijo

`on_mount {MetadataAppWeb.Hooks.Autorizacion, {"sysadmin_usuarios",
"leer"}}` — mismo hook que cualquier página del árbol (deny-by-default,
`administrador` de la empresa siempre pasa, ver `Permissions.
administrador?/2`). A diferencia de un catálogo de negocio, esta
pantalla NO usa el árbol dinámico de navegación (`MetaSchemaContext.
listar_menu_arbol/0`) — pasa su propio `@menu` fijo (línea 61) a
`AdminNav.filtrar_menu/1`, igual que el resto de las pantallas de
Sysadmin (`RolesLive`, `EmpresasLive`, etc.).

## 2. Estado (`socket.assigns`) y ciclo de carga

Dos funciones privadas separan claramente qué se recarga en cada
momento:

- `cargar_usuarios/1` — la lista de la izquierda
  (`Autenticacion.listar_usuarios_de_empresa/1`), depende SOLO de
  `empresa_en_foco`. Se vuelve a llamar al cambiar de empresa
  gestionada, después de un alta, o al quitar/agregar un usuario a la
  empresa.
- `cargar_detalle_usuario/1` — todo lo que depende del usuario
  SELECCIONADO (roles concedidos, capacidades sysadmin, BCs de
  lectura, alcance, form de alias). Se vuelve a llamar después de
  CUALQUIER mutación sobre el usuario seleccionado (agregar/quitar rol,
  togglear capacidad, agregar/quitar branch, etc.) — nunca hay un
  `assign` parcial de un solo campo cuando la mutación pudo afectar
  otro derivado (ej. togglear un branch puede afectar su default).

`empresa_en_foco` es un concepto DISTINTO de `current_scope.
empresa_activa` (ver moduledoc del LiveView, líneas 118-124): la
primera es "qué empresa administra esta pantalla ahora mismo", la
segunda es la empresa real de la sesión que ve el resto de la app. Para
un administrador normal siempre coinciden; solo `super_admin` puede
desacoplarlas (R27).

## 3. Alta de usuarios — dos caminos distintos, cada uno con su semántica

| Camino | Handler | Validación | Efecto |
|---|---|---|---|
| Alta directa por email | `crear_usuario` | Solo formato (`Autenticacion.change_usuario_email/3` con `validate_unique: false`) — un email YA existente no es error, simplemente se suma a la empresa | `agregar_usuario_a_empresa/2` (crea la cuenta si no existe) + `deliver_login_instructions/2` (magic-link) |
| Aceptar de la cola "sin empresa" | `agregar_usuario_sin_empresa` | Ninguna (la cuenta ya existe y ya confirmó email por su cuenta) | `agregar_usuario_a_empresa/2`, sin correo nuevo |

`agregar_usuario_a_empresa/2` no devuelve consistentemente el
`%Usuario{}` (según la rama interna puede devolver el
`%UsuarioEmpresa{}` recién insertado) — el handler `crear_usuario`
vuelve a buscar por email (`get_usuario_by_email/1`) para tener siempre
el struct correcto antes de seleccionar al usuario recién creado.

`rechazar_usuario_sin_empresa` llama `Autenticacion.eliminar_usuario/1`
directo (hard-delete) — es el único punto de esta pantalla sin
soft-delete, justificado porque por definición ese usuario no tiene
ninguna fila dependiente todavía (ni empresa ni rol).

## 4. Pestaña Roles — picker de doble lista (rediseño 2026-09-17, R14-R16c)

Reemplaza el buscador (`busqueda_rol`/`roles_busqueda_resultado`,
`Permissions.buscar_roles/3`) por un picker de doble lista, a pedido
explícito con mockup. Sigue siendo, en el fondo, el mismo mecanismo que
`RolDetalleLive` (eje invertido: ahí se fija un rol y se listan/agregan
usuarios; acá se fija un usuario y se listan/agregan roles) —
solo cambia CÓMO se elige el rol a mover, no qué función del context se
llama.

**Fuente de la lista izquierda**: `Permissions.listar_roles/2` (ya
existía, usado hoy por `RolesLive` — no hubo que crear ninguna función
nueva en `Permissions`), con `incluir_sysadmin?: true` — **decisión
deliberada**: a diferencia de `RolesLive` (que por default esconde los
roles `tipo: :sysadmin` de un admin no-`super_admin`, ver
`roles_live.ex` línea 213), acá se incluyen siempre, porque el
buscador anterior (`buscar_roles/3`) tampoco los filtraba — cambiar eso
habría sido una restricción de alcance nueva, no pedida, más allá del
rediseño de UI. `cargar_detalle_usuario/1` resta los ids ya en
`roles_concedidos` (mismo `MapSet` que ya se arma para R14 original) —
consulta más, no una tabla nueva.

**Nuevos assigns** (reemplazan `busqueda_rol`/`roles_busqueda_resultado`):

| Assign | Qué es |
|---|---|
| `roles_disponibles` | Lista izquierda — roles de la empresa (propios + sistema, TODOS los tipos) que el usuario todavía no tiene |
| `rol_disponible_seleccionado_id` | id resaltado en la lista izquierda (`nil` si ninguno) |
| `rol_concedido_seleccionado_id` | id resaltado en la lista derecha (`nil` si ninguno) |

**Handlers** (R16/R16a/R16b):

```elixir
def handle_event("seleccionar_rol_disponible", %{"id" => id}, socket),
  do: {:noreply, assign(socket, :rol_disponible_seleccionado_id, String.to_integer(id))}

def handle_event("seleccionar_rol_concedido", %{"id" => id}, socket),
  do: {:noreply, assign(socket, :rol_concedido_seleccionado_id, String.to_integer(id))}

def handle_event("mover_rol_a_concedidos", _params, socket) do
  %{usuario_seleccionado: u, empresa_en_foco: e, rol_disponible_seleccionado_id: id} = socket.assigns
  if id, do: Permissions.asignar_rol(u.id, id, e.id)
  {:noreply, socket |> assign(:rol_disponible_seleccionado_id, nil) |> cargar_detalle_usuario()}
end

def handle_event("mover_rol_a_disponibles", _params, socket) do
  %{usuario_seleccionado: u, empresa_en_foco: e, rol_concedido_seleccionado_id: id} = socket.assigns
  if id, do: Permissions.revocar_rol(u.id, id, e.id)
  {:noreply, socket |> assign(:rol_concedido_seleccionado_id, nil) |> cargar_detalle_usuario()}
end
```

Guard `if id` (en vez de un botón `disabled` únicamente del lado
cliente) — mismo criterio defensivo que el resto de la pantalla: un
click de flecha sin nada seleccionado no debe poder ejecutar
`asignar_rol`/`revocar_rol` con un id inventado.

**Ajustes UX (R16d-f, 2026-09-17, mismo día)**:

- **R16d** — la fila que envuelve ambas listas pasa a `style="height:
  70vh"` + `items-stretch` (en vez de `items-start` con cada `<ul>` en
  `h-56 overflow-y-auto`) — mismo patrón `height: 70vh` que ya usa la
  lista maestra de usuarios a la izquierda de la pantalla (línea ~711),
  no una convención nueva. Cada columna pasa a `flex flex-col` y cada
  `<ul>` a `flex-1 min-h-0 overflow-y-auto` para estirarse dentro de esa
  altura.
- **R16e** — botón "Quitar todos" junto al label "Asignados"
  (`quitar_todos_los_roles`, `disabled` si `roles_concedidos == []`,
  `data-confirm` como el resto de acciones destructivas de la
  pantalla): recorre `roles_concedidos` y llama `Permissions.
  revocar_rol/3` por cada uno — no existe (ni hace falta) un
  "revocar-todos" atómico en `Permissions`, son decenas de roles por
  empresa como mucho.
- **R16f** — `mover_rol_a_concedidos` ya no limpia
  `rol_disponible_seleccionado_id` a `nil`: después de
  `cargar_detalle_usuario/1` (que ya recalculó `roles_disponibles` SIN
  el rol recién movido), toma el `id` del primer elemento de esa lista
  nueva. Con la lista vacía, queda `nil` igual que antes (no hay nada
  que seleccionar). El guard `if id` de la próxima llamada a "→" sigue
  siendo la defensa real, no el valor por default.

**Filtro de texto por lista (R16c)** — a propósito SIN assign de
LiveView (ni round-trip al servidor): un hook JS liviano
(`FiltrarListaRoles`, mismo espíritu que `FiltroMenu` del sidebar, ver
`SPEC-SYS-0909202601` §5) montado en cada `<ul>`, no en el `<input>` —
así `updated()` (que dispara cuando ESE `<ul>` se repinta por un
`assign` del servidor, ej. después de mover un rol) puede volver a
aplicar el último texto tipeado sobre los `<li>` recién renderizados.
El `<input>` de cada lista dispara el filtrado por un listener
`input` que el hook cablea en `mounted()`; el texto en sí vive solo en
una variable del hook (`this.filtro`), nunca en `socket.assigns` — dos
inputs independientes, cada uno filtra únicamente su propia lista.

## 5. Pestaña Sysadmin — switches sobre roles de sistema ya sembrados

`Permissions.capacidades_sysadmin/0` devuelve la lista fija
`{recurso, rol_nombre, etiqueta}` (ej. `{"sysadmin_roles", "sysadmin-
roles-admin", "Roles y Permisos"}`); `Permissions.
roles_de_capacidades_sysadmin/0` resuelve esos `rol_nombre` contra los
roles de sistema (`es_sistema: true`) ya existentes en una sola query,
como `%{recurso => %Rol{}}`. `cargar_detalle_usuario/1` cruza ambos
mapas contra `roles_de_usuario/2` del usuario seleccionado para armar
`capacidades_sysadmin_concedidas` (un `MapSet` de recursos).

`toggle_capacidad_sysadmin` resuelve el rol por `recurso` en ese mapa;
si la migración de seed de un capacidad puntual todavía no corrió, el
mapa no tiene esa entrada y el handler no hace nada (`{:noreply,
socket}` sin cambios) — el switch correspondiente ya se renderiza
`disabled` en `switch_capacidad/1` (atributo `resuelto?`), así que en
la práctica ese `case` nunca dispara desde la UI, es la defensa del
lado servidor.

Prender/apagar un switch es exactamente `Permissions.asignar_rol/3` /
`revocar_rol/3` — la misma tabla `usuario_rol` que la pestaña Roles de
al lado, nunca un mecanismo de permisos paralelo (R18).

## 6. Pestaña BC — proyección de solo lectura sobre permisos ya calculados

`Permissions.permisos_de_usuario/2` (cacheado en ETS, TTL — ver
`project_motor_bc_design`) filtrado a `accion == "leer"`, mapeado por
recurso único a través de `MetaSchemaContext.
obtener_headers_por_nombres/1` y ordenado por label. Es el MISMO
cálculo detrás de la poda del árbol de navegación (`SPEC-SYS-0909202601`
§2) — no una query nueva, solo se muestra en vez de usarse para podar.

## 7. Pestaña Alcance — anidada y GLOBAL al usuario (arquitectura ERP)

Rediseñada 2026-08-13 (Fase 7 del modelo de Alcance de Datos): a
diferencia de las otras 4 pestañas (acotadas a `empresa_en_foco`), esta
pestaña es GLOBAL — muestra TODAS las empresas del usuario, no solo la
gestionada.

`cargar_alcance/1` arma el árbol completo desde cero en cada carga
(listas chicas, decenas no miles — evita cualquier desincronización con
lo que `Autenticacion` ya reporta como fuente de verdad):

```
%{empresas, empresas_disponibles, empresa_default_id,
  por_empresa: %{empresa_id => %{branches_asignadas, branches_disponibles, branch_default_id}}}
```

`cargar_alcance_de_empresa/2` resuelve sucursales asignadas/
disponibles + su default; `cargar_alcance_de_branch/3` anida, POR
SUCURSAL, sus Almacenes y Unidades de venta (un almacén pertenece a una
sola branch — nunca se mezclan entre sucursales, ver `UsuarioBranch`)
más sus defaults vía `Autenticacion.defaults_de_branch/2`.

**4 pares gemelos agregar/quitar** (Empresa, Sucursal, Almacén, Unidad
de venta) comparten el mismo patrón de handler:
`agregar_*_a_usuario/3` con guard `when id not in [nil, ""]` (el
`<select required>` es defensa solo del lado cliente) delega en
`Autenticacion.asignar_branch/2` / `asignar_sales_unit/2` /
`asignar_inventory_location/2` / `agregar_usuario_a_empresa/2`; los
`quitar_*` en sus contrapartes `revocar_*`/`remover_usuario_de_
empresa/2`.

**3 pares gemelos de default** (`toggle_branch_default`,
`toggle_inventory_default`, `toggle_sales_unit_default`) — mismo
criterio toggle: si el id clickeado ya es el default, se limpia (nil);
si no, se fija (reemplaza cualquier default previo de esa dimensión sin
paso aparte, el campo es un id único, no una lista). Los 3 llaman a
`Autenticacion.definir_*_default_de_*/3-4` pasando `es_administrador?`
(`Permissions.administrador?/2`) porque el default de Sucursal es POR
EMPRESA y el de Almacén/Unidad de venta es POR SUCURSAL puntual — un
`administrador` bypasea la validación de que el id destino ya esté
asignado (ve/puede default-ear cualquier branch de la empresa aunque no
esté explícitamente asignada). `toggle_empresa_default` es la
excepción: vive en `Usuario` (cross-empresa, no en `UsuarioEmpresa`),
por eso llama `Autenticacion.definir_empresa_default/2` sin
`es_administrador?` — no hay bypass de "todas las empresas", solo
puede marcar default una a la que ya pertenece.

Los 4 pares comparten el mismo nombre de param HTML (`phx-value-id` /
`name="id"`) porque HEEx no permite atributos dinámicos
(`phx-value-{@campo}` no es válido) — el NOMBRE DEL EVENTO ya identifica
la dimensión, no hace falta un param distinto por cada una. El botón de
"Quitar empresa en foco" (`quitar_empresa_de_usuario`) es el único caso
con una rama especial: si el id coincide con `empresa_en_foco.id`,
además de refrescar el detalle saca al usuario de la lista visible y
cierra el panel (R26) — cualquier otra empresa solo refresca
`cargar_detalle_usuario/1`.

## 8. Componentes privados de render reusados

- `celda_lista/1` — la celda de tabla Almacén/Unidad de venta: lista de
  asignados (con punto de default + botón quitar) + `<form>` compacto
  de agregar. Un solo componente parametrizado por
  `nombre_campo`/`evento_agregar`/`evento_quitar`/`evento_default` sirve
  para ambas columnas (rediseño 2026-08-13, "respeta mi bosquejo": tabla
  Empresa | Sucursal | Almacén | Unidad de venta, un ● verde marca el
  default).
- `switch_capacidad/1` — switch visual con colores Tailwind explícitos
  (no el "toggle" de daisyUI, mismo motivo que
  `ConfiguracionCuentaModal`: verse igual sin importar el theme de la
  página).

## 10. Eliminación total del usuario (R13a-e)

Reusa `Autenticacion.eliminar_usuario/1` (ya existente, hoy solo
llamado desde `rechazar_usuario_sin_empresa` — pestaña "sin empresa",
§3) — es un `Repo.delete(usuario)` liso, sin lógica propia de cascada
en Elixir: el borrado en cascada ya está resuelto a nivel de FK en
Postgres (confirmado leyendo las migraciones, no asumido):

| Tabla dependiente | `on_delete` |
|---|---|
| `meta_schema_usuario_tokens` | `:delete_all` |
| `meta_schema_usuario_empresa` | `:delete_all` |
| `meta_schema_usuario_rol` | `:delete_all` |
| `meta_schema_usuario_branch` / `_sales_unit` / `_inventory_location` | `:delete_all` |
| `meta_schema_notificacion` | `:delete_all` |
| `meta_schema_usuario_sesion_movil` | `:delete_all` |
| `meta_schema_accion_log.usuario_id` | `:nilify_all` (se conserva el log, sin autor) |
| `meta_fixture_alcance.creado_por_id` | `:nilify_all` |

Es decir: `eliminar_usuario/1` YA hace exactamente lo que pide R13a
(borrado total, sin importar empresas) — no hace falta tocar
`Autenticacion` ni agregar una transacción manual. El trabajo real es
exponerlo desde `UsuariosEmpresaLive` con las guardas de R13c/R13d, que
SÍ son nuevas.

**Guardas (R13c/R13d)** — evaluadas en el render, no solo escondiendo
el botón: el handler `eliminar_usuario` en el LiveView revalida del
lado servidor antes de llamar `Autenticacion.eliminar_usuario/1`
(mismo criterio defensivo que `cambiar_empresa_en_foco`, línea 134-135
— nunca confiar en que el cliente no mande el evento):

```elixir
def handle_event("eliminar_usuario", _params, socket) do
  %{usuario_seleccionado: usuario, current_scope: scope} = socket.assigns

  cond do
    usuario.id == scope.usuario.id -> {:noreply, socket}
    usuario.super_admin -> {:noreply, socket}
    true ->
      Autenticacion.eliminar_usuario(usuario)
      # R13e: mismo reset que cerrar_detalle/2 + recarga de la lista
  end
end
```

El botón en el render (`.pestaña Generales`, junto a "Cerrar todas las
sesiones") se oculta con `:if={@usuario_seleccionado.id !=
@current_scope.usuario.id and not @usuario_seleccionado.super_admin}` —
mismo patrón `data-confirm` que ya usan "Rechazar" (§2) y "Cerrar
sesiones" (§4), texto explícito de que no se puede deshacer (R13b).

No se necesita invalidar el cache de `Permissions` (`invalidar_cache/2`)
aparte — el usuario ya no existe, cualquier lookup futuro por su id
simplemente no encuentra nada.

## 11. Fuera de alcance (igual que requirements.md §10)

Mecanismo interno de RBAC (`Permissions`), pantallas Roles/Empresas
(eje invertido, specs propias), modelo de datos de Alcance
(`Autenticacion.Scope`), "Desactivar cuenta" (pendiente, distinto de
"Eliminar usuario" — desactivar preserva la cuenta y su historial,
eliminar no).
