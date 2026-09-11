# SPEC-SYS-1109202605 — BC Motor: Tab Permisos y Alcance de Datos

**Documento:** Design · **Fase:** ✅ aprobada (2026-09-11).

Documentación retroactiva — describe el mecanismo tal como existe en
`lib/metadata_app_web/live/sysadmin/catalogo_permisos_live.ex`
(módulo completo, embebido en `BcMotorLive` vía `live_render/3`) +
`tabla_permisos_detalle/1`/`toggle_permiso_detalle/1` en
`bc_motor_live.ex:3022-3082` (Permisos de detalle, único trozo de
esta spec que vive fuera de `CatalogoPermisosLive`).

## 1. Visibilidad y montaje embebido (R1)

`bc_motor_live.ex:2039-2041` incluye `%{key: "permisos", label:
"Permisos"}` dentro de `unless(@es_detalle?, do: [...])` — mismo
patrón que Diagrama/Contrato. El panel:

```elixir
<div id="motor-panel-permisos" class="hidden space-y-4">
  {live_render(@socket, MetadataAppWeb.Sysadmin.CatalogoPermisosLive,
    id: "permisos-embebido-#{@header.schema_context_name}",
    session: %{"recurso" => @header.schema_context_name}
  )}
  <.tabla_permisos_detalle :if={@catalogos_detalle != []} .../>
</div>
```

`CatalogoPermisosLive.mount/3` tiene 3 cláusulas según cómo se monta
— la relevante acá es `mount(_params, %{"recurso" => recurso},
socket)` (child LiveView, `session` en vez de `params` — un hijo
montado vía `live_render/3` SIEMPRE recibe `params ==
:not_mounted_at_router`, así que el dato viaja por `session`, nunca
por la URL). `@embebido? = true` en este camino: sin picker de
catálogo a la izquierda, sin link "volver", el catálogo queda FIJO
para toda la vida de esa instancia (`render/1` condiciona ambos con
`:if={!@embebido?}`).

**Nota de diseño real (no requisito de esta spec)**: esta misma
LiveView, en su uso STANDALONE ("Permission Sets", fuera de BC
Motor), sí permite buscar y elegir directamente un catálogo DETALLE
(sin pasar por la restricción de tab de R1) — `cargar_matriz/1` ya
contempla ese caso (`acciones_crud` le saca "Eliminar", ver §2),
consistente aunque el camino de llegada sea distinto.

## 2. Matriz de permisos por rol (R2-R5)

`cargar_matriz/1` (`catalogo_permisos_live.ex:325-388`):

```elixir
acciones_crud =
  cond do
    socket.assigns.catalogo.es_consulta -> ~w(leer)
    socket.assigns.catalogo.es_detalle -> @acciones_crud -- ~w(eliminar)
    true -> @acciones_crud
  end
```

(R2a) — una Consulta no tiene módulo Ecto real detrás
(`CatalogoController.resolver/1` nunca la trata como catalog CRUD
completo), ofrecer "crear"/"editar"/"eliminar" sugeriría una
capacidad inexistente. Un catálogo detalle: `CatalogoGenerico.eliminar/2`
rechaza siempre con "los renglones de un catálogo detalle no se
borran, use una transición" — mismo motivo, se saca del todo.

`acciones_todas = acciones_crud ++ Enum.map(transiciones, & &1.accion)`
— `Permissions.estado_permisos_para_roles/3` trae, en una sola
consulta, qué `{rol_id, accion}` ya están concedidos para TODOS los
roles y acciones de una — nunca una consulta por celda de la matriz.

`toggle_permiso` (R3): `Permissions.conceder_permiso_catalogo/3` o
`revocar_permiso_de_rol/2` según el estado actual de esa celda
puntual, seguido de `cargar_matriz(socket)` completo (recalcula toda
la matriz, no solo la celda tocada — consistente con el resto del BC
Motor, que siempre recarga assigns completos tras cualquier cambio).

`conceder_todos`/`revocar_todos` (R5) filtran primero
`todas_las_acciones(socket) |> Enum.reject/filter(&ya_concedido?)`
antes de llamar `Permissions.conceder_permisos_catalogo/2` /
`revocar_permisos_de_rol/2` (variantes en lote de la misma función) —
un solo request al servidor, no N toggles individuales.

El rol `"administrador"` (R4) se renderiza con `disabled={rol.nombre
== "administrador"}` en cada botón y sin los atajos "Todos"/"Ninguno"
— es una fila puramente informativa, `Permissions.can?/3` ya lo trata
como comodín en cualquier catálogo sin consultar esta tabla.

## 3. Filtro de la matriz (R6-R7)

`@modo` (`:todos` | `:por_usuario`) decide el origen de `roles` en
`cargar_matriz/1`: `Permissions.listar_roles/2` (con
`incluir_sysadmin?` según el checkbox de R7, calculado como
`@mostrar_sysadmin? and current_scope.usuario.super_admin` — doble
guardia, el checkbox ni siquiera se renderiza para quien no es
`super_admin`, y el server-side lo vuelve a chequear en el
`handle_event` por defensa en profundidad) o
`Permissions.roles_de_usuario/2` (sin filtro de sysadmin — se
muestra lo que ESE usuario realmente tiene, sea lo que sea).

## 4. Alcance de Datos — activación (R8-R10)

`catalogo_base_de_consulta/1` resuelve, solo para una Consulta, el
`header` del catálogo base real (`MetaConsultas.obtener_por_header_id/1`
+ `MetaSchemaContext.obtener_header_por_nombre/1`) — el render (R8)
muestra ese estado heredado en modo informativo puro, sin ningún
`phx-click`.

`toggle_alcance_habilitado` (R9-R10):

```elixir
resultado =
  if valor do
    MetaSchemaContext.provisionar_alcance(header)
  else
    MetaSchemaContext.actualizar_header(header, %{"alcance_habilitado" => false})
  end
```

Activar usa `provisionar_alcance/1` (NO
`activar_alcance_con_default_sucursal/1`, reservada para cuando un BC
nace) — togglear acá nunca pisa un `alcance_tipo` que un admin ya
haya configurado por rol antes. Desactivar es un `UPDATE` de un solo
campo (`alcance_habilitado: false`) — ninguna columna física ni fila
de `meta_schema_rol_alcance` se toca, 100% reversible (R10).

## 5. Alcance de Datos por rol (R11-R14)

`panel_alcance_de_rol/1` (`catalogo_permisos_live.ex:633-`) solo se
renderiza `:if={@catalogo && not @catalogo.es_consulta &&
@catalogo.alcance_habilitado}`. Recibe `@roles_con_permiso` (R12) —
NO `@roles` — calculado en `cargar_matriz/1`:

```elixir
roles_con_permiso =
  Enum.filter(roles, fn rol ->
    rol.nombre == "administrador" or
      Enum.any?(acciones_todas, &Map.get(estado, {rol.id, &1}, %{concedido: false}).concedido)
  end)
```

`@tipos_alcance` (R11) es una lista fija ordenada, de más
restrictivo a más amplio (`propio → inventory_location → sales_unit →
branch → empresa → global`) — el `<select>` se lee de arriba a abajo
como una escala real. `cambiar_alcance_tipo`:

```elixir
def handle_event("cambiar_alcance_tipo", %{"rol_id" => rol_id, "tipo" => tipo}, socket) when tipo != "" do
  Permissions.definir_alcance_de_rol(rol_id, socket.assigns.catalogo.id, tipo)
  {:noreply, cargar_matriz(socket)}
end

def handle_event("cambiar_alcance_tipo", _params, socket), do: {:noreply, socket}
```

`tipo != ""` como guard, más una cláusula catch-all que no hace nada
— defensa contra un evento con `tipo` vacío (no debería pasar, el
`<select>` siempre manda un valor real, pero mejor dejar la fila como
estaba que perder una concesión por un evento raro). `"administrador"`
(R13) tiene su `<select disabled>`. `Map.get(@alcance_por_rol, rol.id,
:propio)` (R14) — sin fila en `meta_schema_rol_alcance`, el default
es `:propio`, nunca un nivel más amplio.

Ambos handlers de alcance (`cambiar_alcance_tipo`,
`toggle_alcance_habilitado`) tienen una cláusula previa que
intercepta el caso `catalogo.es_consulta: true` con un
`put_flash(:error, ...)` — defensa en profundidad: el UI ya oculta
estos controles para una Consulta (R8), esto cubre un evento
manual/directo igual.

## 6. Permisos de detalle por estado (R15-R17)

Mecanismo COMPLETAMENTE APARTE de RBAC — no usa `Permissions` ni
`meta_schema_permiso`. `tabla_permisos_detalle/1` arma una matriz
Estado × (catálogo detalle × acción), leída de
`meta_schema_estado_detalle_permiso` (vista en sesiones anteriores de
este proyecto: `permite_insertar`/`permite_actualizar`/`permite_borrar`,
únicas por `{meta_schema_estado_id, meta_schema_header_detalle_id}`).
`@permisos_detalle` es un mapa `%{{estado_id, detalle_id} =>
%{permite_insertar, permite_actualizar, permite_borrar}}` — sin fila
para una combinación puntual, el default es `false` en las 3
(`Map.get(@permisos_detalle, {...}, %{permite_insertar: false, ...})`).

`toggle_permiso_detalle/1` (component) + `handle_event("toggle_permiso_detalle",
%{"estado_id" => ..., "header_detalle_id" => ..., "campo" => ...},
socket)` (en `bc_motor_live.ex`, no en `CatalogoPermisosLive`) —
upsert directo de esa fila, un campo booleano por vez, mismo criterio
inmediato (sin confirmar) que el resto de los toggles de este tab.

Este es el mecanismo que `MetaEstadosAdmin.permiso_detalle/2`
consulta en tiempo real cuando alguien intenta insertar/editar/borrar
un renglón de un catálogo detalle — deny-by-default: sin fila
configurada, el estado actual del maestro NO permite tocar renglones
de ningún catálogo detalle.

## 7. Fuera de alcance

Igual que `requirements.md` §7.
