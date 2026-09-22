# SPEC-SYS-1709202602 — Sysadmin / Permission Sets (picker standalone de Permisos por catálogo)

**Documento:** Design · **Fase:** ✅ aprobada (2026-09-17). **§1 y §4
actualizadas el mismo día** — incremento real completo (picker que no
pierde el filtro al elegir catálogo, R4/R4a-b; comodín "*", R9), ver
`tasks.md`.

Documentación retroactiva — describe el mecanismo tal como existe en
`lib/metadata_app_web/live/sysadmin/catalogo_permisos_live.ex`. Es el
MISMO módulo que documenta `SPEC-SYS-1109202605` §1-§6 para el uso
embebido en `BcMotorLive` — acá solo se documenta lo que cambia según
`@embebido?` y las 3 formas de `mount/3`.

## 1. Tres formas de `mount/3` — por qué

Este LiveView **nunca** implementa `handle_params/3`, a propósito (ver
comentario extenso en el código, línea 60-74): cuando se monta como
hijo de `BcMotorLive` vía `live_render/3`, `socket.root_pid !=
self()` siempre, y `Phoenix.LiveView.Channel.
maybe_call_mount_handle_params/4` fuerza `router: nil` en ese caso —
si el módulo definiera `handle_params/3`, revienta con "cannot invoke
handle_params/3... because it is not mounted nor accessed through the
router live/3 macro" apenas conecta el WebSocket. Esto no es un bug de
esta pantalla — le pasa a CUALQUIER LiveView con `handle_params/3`
usado como hijo.

Consecuencia de diseño: TODA la resolución de "qué catálogo mostrar"
vive en `mount/3`, con 3 cláusulas según de dónde viene el dato:

| Cláusula | Cuándo | De dónde sale `recurso` | `@embebido?` |
|---|---|---|---|
| `mount(%{"recurso" => recurso}, _session, socket)` | Ruta `/sysadmin/catalogos/:recurso/permisos` | Params de la URL (router) | `false` |
| `mount(_params, %{"recurso" => recurso}, socket)` | Embebido en `BcMotorLive` | `session` (un hijo SIEMPRE recibe `params` fijo en `:not_mounted_at_router`, así que el dato viaja por session, no por params) | `true` |
| `mount(_params, _session, socket)` | Ruta `/sysadmin/catalogos/permisos` (sin recurso) | Ninguno — `catalogo: nil` | `false` |

**Corregido 2026-09-17** (R4) — el picker de catálogo sigue navegando
con `push_navigate/2` (remonta entero), pero ahora lleva el texto
buscado como query param `?q=` en la URL destino; `mount/3` (ruta 1)
lo lee y restaura el picker antes de armar el catálogo — ver §4 para
el detalle completo.

**Intento descartado, documentado para no repetirlo**: la primera
versión de este fix cambiaba `elegir_catalogo` a `push_patch/2` +
resolver el catálogo en el mismo evento (sin remount), asumiendo que
alcanzaba con que el LiveView estuviera montado por el router
(`@embebido? == false`) para que `push_patch` funcionara sin
`handle_params/3` — razonamiento basado en leer `Phoenix.LiveView.
Channel.maybe_call_mount_handle_params/4`, que efectivamente SÍ tolera
la ausencia de `handle_params/3` al MONTAR. Un test real lo tumbó:
`push_patch/2` disparado desde una sesión YA CONECTADA (el caso real,
un click del usuario) pasa por
`Phoenix.LiveView.Channel.sync_handle_params_with_live_redirect/5`, que
llama `Utils.call_handle_params!/3` **sin** el resguardo `not
lifecycle.any?` que sí tiene el camino de montaje — revienta con
`UndefinedFunctionError` sin importar si el LiveView está o no montado
por el router. Y definir `handle_params/3` para evitarlo reintroduce
exactamente el crash original que ese callback evita a propósito
(rompe el uso embebido en `BcMotorLive`, ver comentario de `mount/3`
más abajo) — `push_patch`/`handle_params` quedan descartados por
completo para este módulo compartido, en cualquier dirección. Lección:
leer el código fuente de un mecanismo de Phoenix identifica lo que
PUEDE pasar en el camino que se leyó, pero no sustituye correr el
camino real (acá, un evento sobre una conexión ya viva) — la
verificación real encontró lo que la lectura sola no iba a encontrar.

**Por qué el enfoque final (query param) es mejor, no solo "más
seguro"**: al ser `push_navigate/2` real, cada catálogo elegido sigue
generando una entrada de historial del navegador completa — atrás/
adelante entre catálogos ya visitados SÍ recarga sus datos
correctamente (a diferencia del intento con `push_patch`, que hubiera
tenido ese tradeoff). Y F5/recarga directa de cualquier URL sigue
funcionando exactamente igual que antes (R4b) — sin `?q=` en la URL,
el picker arranca vacío; si la URL SÍ tenía `?q=` (por ejemplo, un
link compartido a mitad de una búsqueda), recargarla muestra ese mismo
filtro, que es el comportamiento esperado de cualquier URL con query
string.

## 2. `@embebido?` — qué chrome se oculta

`render/1` es UN SOLO template para los dos usos; `@embebido?`
controla, vía `:if`, qué partes de chrome se muestran:

- Wrapper con padding (`w-full p-4 sm:p-6...`) vs sin padding (cuando
  está embebido, el padding ya lo da `BcMotorLive`).
- Encabezado con botón "volver" + label del catálogo (R7) — NUNCA en
  modo embebido (ya se está "adentro" de ese BC).
- Picker de catálogo de la izquierda (R2-R4) — NUNCA en modo embebido
  (el catálogo ya está fijo, no hay nada que elegir).
- El grid pasa de 2 columnas (`sm:grid-cols-[220px_1fr]`, picker +
  matriz) a 1 sola cuando está embebido.

Todo lo DEMÁS del template (matriz de permisos, Alcance de Datos,
filtro por usuario/Sysadmin) es idéntico en ambos modos — mismos
`assigns`, mismos `handle_event`, ver `SPEC-SYS-1109202605` §2-§5.

## 3. `montar_base/1` y `montar_catalogo/2` — compartidas por las 3 cláusulas

`montar_base/1` inicializa los assigns comunes (picker, filtro por
usuario, `@modo`, `@tipos_alcance`, etc.) — llamada por las 3 formas de
`mount/3` por igual, así no hay divergencia de estado inicial según de
dónde se entró.

`montar_catalogo/2` (`Permissions.obtener_catalogo/1` +
`cargar_matriz/1`, ver `SPEC-SYS-1109202605` §2 para el detalle de
`cargar_matriz/1`) es lo que arma el catálogo cuando SÍ viene un
`recurso` (rutas 1 y 2 de la tabla de arriba) — si
`Permissions.obtener_catalogo/1` devuelve `nil` (R6), `catalogo` queda
`nil` y la cláusula de ruta 1 hace el `put_flash` +
`push_navigate/2` de vuelta a la raíz (la cláusula embebida, ruta 2,
NO tiene ese fallback — si `BcMotorLive` pasa un recurso inválido por
session es un bug de ESE caller, no algo que esta pantalla necesite
manejar de nuevo).

## 4. Picker de catálogo (R2-R4, R9)

`buscar_catalogo_picker` → `Permissions.buscar_catalogos/2` (ilike +
límite, mismo patrón de escala que `buscar_roles/3`/`buscar_usuarios_
de_la_empresa/3` en el resto de RBAC — nunca cargar los +1000
catálogos posibles de una).

**`elegir_catalogo` (corregido 2026-09-17, R4/R4a-b)**: sigue el mismo
`push_navigate/2` de siempre, ahora con el texto buscado en la URL:

```elixir
def handle_event("elegir_catalogo", %{"recurso" => recurso}, socket) do
  destino =
    case socket.assigns.busqueda_catalogo_picker do
      "" -> ~p"/sysadmin/catalogos/#{recurso}/permisos"
      texto -> ~p"/sysadmin/catalogos/#{recurso}/permisos?#{[q: texto]}"
    end

  {:noreply, push_navigate(socket, to: destino)}
end
```

Del otro lado, `mount(%{"recurso" => recurso} = params, _session,
socket)` (§1, ruta 1) pasa `params["q"]` por una función nueva ANTES de
`montar_catalogo/2`:

```elixir
defp restaurar_busqueda_picker(socket, texto) when texto in [nil, ""], do: socket

defp restaurar_busqueda_picker(socket, texto) do
  assign(socket, busqueda_catalogo_picker: texto, resultados_catalogo_picker: Permissions.buscar_catalogos(texto))
end
```

R4a se cumple porque la URL ES la fuente de verdad del filtro (mismo
criterio que R6 ya usa para el catálogo elegido) — nunca hace falta
"preservar" nada en memoria del cliente ni en `sessionStorage`: cada
remount simplemente vuelve a leer de dónde viene, igual que siempre.

Mismo criterio para "elegir catálogo no vacía el picker" (R4a) en el
resto de acciones (`toggle_permiso`, `conceder_todos`, etc.) — ninguna
de ellas TOCA `busqueda_catalogo_picker`/`resultados_catalogo_picker`
(ver `SPEC-SYS-1109202605` §2-§5), así que R4a ya se cumplía ahí sin
cambios; el único punto que SÍ los perdía (por el remount completo sin
`?q=`) era `elegir_catalogo`, ya corregido arriba.

**Comodín "*" (R9)**: nuevo clause head en `Permissions.
buscar_catalogos/2` — `def buscar_catalogos("*", limite), do:
query_catalogos(true, limite)`, factorizando el query base (antes
inline) a una `defp query_catalogos(condicion_texto, limite)` común,
que la búsqueda por texto también pasa a usar (con un `dynamic([header:
h], ilike(...) or ilike(...))` en vez del `true` literal). Se agrega en
`Permissions` (no como un caso especial dentro del LiveView) porque es
el mismo contrato/función que ya usa este picker — cualquier otro
futuro caller de `buscar_catalogos/2` hereda el comodín gratis, sin
tocar el LiveView. El clause de `buscar_catalogos("", _limite), do:
[]` (texto vacío = nada, a propósito) queda intacto — "*" es un pedido
EXPLÍCITO distinto de "no escribí nada todavía".

**Bug real encontrado y corregido al factorizar** (no en el código
anterior, introducido y arreglado en el mismo cambio): la primera
versión metía `^condicion_texto` DENTRO de una cadena `and` armada a
mano junto al resto de condiciones en un solo `where:` — Ecto lo
rechaza en tiempo de ejecución (`Ecto.QueryError`: "dynamic expressions
can only be interpolated at the top level of where..."), confirmado
corriendo el test, no en `mix compile` (Ecto arma el SQL en runtime,
no en compile-time). Arreglado repitiendo `where:` como cláusula
separada (Ecto las combina con AND automáticamente) — así
`^condicion_texto` queda como fragmento top-level, válido tanto para
un `dynamic(...)` real como para el `true` literal del caso "*".

## 5. Menú y navegación (R8)

Esta pantalla usa su propio `@menu` fijo (línea 44, idéntico al de
`RolesLive`/`UsuariosEmpresaLive`/etc.) pasado a `AdminNav.
filtrar_menu/1` — `current_page: "roles"` (comparte resaltado de menú
con `RolesLive`, no tiene una entrada de sidebar propia separada). El
acceso real "Permission Sets" vive en el menú administrativo
(`MenuLayout`, ver `SPEC-SYS-0909202601` §3) — gateado por el mismo
permiso `sysadmin_catalogos_permisos/leer` que el `on_mount` de esta
pantalla, no un mecanismo de visibilidad aparte.

## 6. Fuera de alcance (igual que requirements.md §5)

Matriz de permisos/Alcance de Datos en sí (`SPEC-SYS-1109202605`
§2-§5), "Permisos de detalle por estado" (no existe acá), modelo de
datos de RBAC.
