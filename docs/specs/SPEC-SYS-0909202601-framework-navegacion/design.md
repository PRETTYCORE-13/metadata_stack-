# SPEC-SYS-0909202601 — Framework de Navegación

**Documento:** Design · **Fase:** ✅ aprobada (2026-09-09).

Documentación retroactiva — describe el mecanismo tal como existe en
`lib/metadata_app_web/components/menu_layout.ex` (componente único,
`MetadataAppWeb.MenuLayout.sidebar/1`, usado por `Layouts.app` en toda
pantalla autenticada) + los hooks JS de `assets/js/app.js`.

**§7 actualizada (2026-09-09, a pedido explícito)** — a diferencia del
resto del documento (retroactivo, sin tocar código), §7 SÍ describe un
cambio real todavía no implementado: la reorganización del menú
administrativo en dos grupos + un segundo punto de entrada desde el
sidebar. Ver `tasks.md` para la ejecución.

## 1. Fuente del árbol de navegación

El árbol sale de `MetaSchemaContext.listar_menu_arbol/0`: todos los
`meta_schema_header` con `schema_visible: true`, mapeados a un item
plano (`id`, `label`, `nav`, `icono`, `es_carpeta`, `es_consulta`, ...)
y anidados en `construir_arbol/1` según los segmentos de `nav`
(`"/carpeta/subcarpeta/pagina"` → carpeta > subcarpeta > página hoja) —
mismo modelo que un árbol de carpetas de sistema de archivos, sin tabla
de jerarquía aparte.

Cada `LiveView` puede pasar su propio `menu_items` fijo en vez del
dinámico (usado hoy solo por las pantallas de Sysadmin, que no son
catálogos de negocio).

## 2. Poda por permisos (RBAC)

`podar_menu_por_permisos/1` corre en cada render del sidebar: una sola
consulta a `Permissions.permisos_de_usuario/2` (ya cacheada en ETS, ver
`project_motor_bc_design`), nunca un `can?/3` por nodo. Recorre el
árbol recursivo, se queda solo con páginas que tengan permiso
`"leer"` concedido, y elimina cualquier carpeta que quede sin hijos
después de podar. Deny-by-default: sin scope resuelto (login/registro,
donde este layout casi no se usa) el árbol se muestra completo, no hay
de dónde sacar permisos.

## 3. Estado de UI persistente (client-side, sin servidor)

Todo lo que el usuario "ajusta" del framework (ancho, abierto/cerrado,
tema) se guarda en `localStorage` del navegador vía hooks JS — ningún
viaje al servidor, ninguna fila en base:

| Qué | Hook / mecanismo | Llave localStorage |
|---|---|---|
| Ancho del sidebar | `RedimensionarSidebar` (drag del handle) | `pc-sidebar-width` |
| Ancho del flyout | `RedimensionarFlyout` | `pc-flyout-width` |
| Sidebar abierto/cerrado | `PersistirSidebarAbierto` | `pc-sidebar-open` |
| Tema claro/oscuro | `phx:set-theme` (listener en `root.html.heex`, generado por `mix phx.new`, sin cambios) | (llave propia del generador, no tocada por este framework) |
| Firma de Unidad Operativa vista | `UnidadOperativaWatcher` | `pc_unidad_operativa_firma` |

## 4. Flyout de carpeta raíz — 100% CSS, sin servidor

Cada carpeta de nivel 0 es un `<details>` con `name="pc-menu-raiz-group"`
— el navegador ya garantiza que abrir uno cierra cualquier otro del
mismo grupo (comportamiento nativo de `<details name=...>`, sin JS). El
panel flotante (`.pc-sidebar-flyout`) se muestra u oculta con un
selector `:has()` sobre el atributo `[open]` de esos `<details>` (CSS
puro, `menu.css`) — abrir una carpeta raíz por lo tanto abre su flyout
solo, sin ningún evento a LiveView. El hook `EvitarToggleNativoCarpetas`
existe únicamente para que el toggle nativo del navegador (que compite
con el `phx-click` que fuerza `open=true` explícito) no revierta el
estado ~8ms después — confirmado en vivo con un `MutationObserver`
durante el desarrollo original.

## 5. Búsqueda del sidebar

`FiltroMenu` (hook JS, `phx-update="ignore"`): filtra el árbol ya
renderizado por texto tipeado, ocultando ramas sin ninguna coincidencia
(recursivo — una carpeta con al menos un hijo que matchea se abre sola
para mostrarlo) y soporta pegar una ruta directa para navegar. Sin
round-trip al servidor — opera sobre el DOM ya presente.

## 6. Responsive / móvil

Un solo breakpoint CSS (`menu.css`) decide:
- Sidebar oculto por default, mostrado con clases toggleadas 100%
  client-side (`pc-sidebar-visible` / `pc-sidebar-overlay-visible`,
  `JS.toggle_class` — sin servidor) desde el botón hamburguesa de la
  topbar; cerrado automático al navegar (`mobile_close_js/0`) o al
  tocar el overlay.
- Footer oculto por default (`@media max-width: 768px`), revelado con
  la clase `pc-footer-abierto` desde un botón dedicado — mismo criterio
  100% client-side, sin lógica Elixir de por medio.

## 7. Menú administrativo — dos grupos, dos accesos al mismo contenido

Reemplaza `capacidades_sysadmin_visibles/2` (una sola lista plana de 11
capacidades, todas gateadas igual) por DOS listas resueltas por
separado, en la misma función/asigns compartidos por ambos triggers:

- **Grupo "administrativo"** (Roles Admin, Empresas, RBAC Usuarios,
  RBAC Business Context, Jerarquía organizacional) — sigue igual que
  cualquier otra página del árbol: `Permissions.can?/3` sobre su
  recurso `sysadmin_*`, sin ningún gate adicional. Ya NO depende de que
  el usuario sea sysadmin — un usuario de una empresa cliente con ese
  permiso concedido las ve, en cualquier ambiente (developer, unstable,
  testing, stable, cliente).
- **Grupo "plataforma"** (Credenciales, Ambientes de Deploy, Panel de
  Control, Acciones externas, + Business Process Builder/Tepache solo
  si además `bpb_habilitado`) — gate NUEVO: `usuario.super_admin ==
  true` (mismo campo ya usado por `Autenticacion.existe_sysadmin?/0`
  para el bootstrap de primer arranque — no se inventa un concepto
  nuevo, se reusa el que ya existe). Ya NO alcanza con tener el permiso
  RBAC del catálogo — sin `super_admin`, estas opciones no aparecen
  aunque el rol tenga el permiso concedido.

**Corregido el mismo día**: la primera versión instanciaba el
componente dos veces (avatar de topbar + engrane del sidebar). A
pedido explícito se sacó el acceso desde el avatar — el botón de
usuario de la topbar (`pc-user-menu-btn`) queda sin `phx-click` ni
dropdown asociado, puramente informativo (avatar/inicial + nombre).
Único punto de entrada real: el engrane del sidebar
(`#sidebar-config-dropdown`, mismo patrón de anclaje ya descrito en la
versión anterior de esta sección — `position: fixed` porque
`.pc-platform-sidebar` tiene `overflow: hidden`).

El panel reusa la MISMA presentación visual que el flyout de catálogos
de negocio (`.pc-flyout-header`/`.pc-flyout-nav`, ver §4) — a pedido
explícito ("no tiene caso generar una UI diferente, se ve mal"): header
con título "Configuración" + botón de cerrar, ítems con ícono (Material
Symbols) + etiqueta, en vez del dropdown compacto sin íconos de la
primera versión.

Lista vacía en ambos grupos → ni el botón de engrane se renderiza
(nunca un botón que abre un menú vacío).

## 8. Footer — jerarquía operativa de solo lectura

`opciones_jerarquia_activa/1` resuelve las 4 listas (Empresas, Branches,
Inventory Locations, Sales Units) que ALIMENTAN el modal "Cambiar Unidad
Operativa" (`CambiarUnidadOperativaModal`, live_component aparte — no
es responsabilidad de esta spec). Un `administrador` (bypass total,
mismo criterio que `alcance_tipo_efectivo/2`) ve TODAS las branches de
la empresa; cualquier otro usuario ve solo las que tiene explícitamente
asignadas. Almacén y Unidad de Venta siempre se acotan a la Sucursal
ACTIVA — nunca "todos los de la empresa" — y quedan vacíos hasta que
haya una sucursal elegida.

La "firma" comparada por `UnidadOperativaWatcher` es
`Empresa+Sucursal+Almacén` (a propósito, sin Sales Unit — opcional en
el modelo ERP) — 100% client-side, el servidor solo expone la firma
ACTUAL en cada render, nunca guarda "la anterior".

## 9. Componentes vivos aparte, reusados por el framework

- `MetadataAppWeb.NotifBellComponent` (campana de notificaciones).
- `MetadataAppWeb.ConfiguracionCuentaModal` ("Configuración de cuenta").
- `MetadataAppWeb.CambiarUnidadOperativaModal` ("Cambiar Unidad
  Operativa").

Ninguno de los tres se documenta acá en detalle — son
`live_component`s propios, con sus propias specs si hiciera falta.

## 10. Fuera de alcance (igual que requirements.md §5)

Contenido de cada pantalla del menú, mecanismo interno de RBAC
(`Permissions`), paleta/tokens CSS.
