# SPEC-SYS-1709202602 — Sysadmin / Permission Sets (picker standalone de Permisos por catálogo)

**Documento:** Tasks · **Fase:** ✅ completa (2026-09-17) — código,
tests y verificación real, todo pasando. El enfoque técnico cambió a
mitad de camino respecto de lo planeado originalmente (ver Grupo A) —
un intento con `push_patch` se descartó por un bug real de Phoenix
encontrado con un test, no asumido.

Este `tasks.md` cubre exclusivamente el incremento de "picker que no
pierde el filtro" (R4/R4a-b) + "comodín \*" (R9). El resto de la spec
es documentación retroactiva, sin tasks.

## Grupo A — Picker persistente al elegir catálogo (R4/R4a-b) ✅

- [x] A1. `handle_event("elegir_catalogo", ...)` sigue con
      `push_navigate/2`, ahora agregando el texto del picker como query
      param `?q=` en la URL destino. **Plan original descartado**:
      `push_patch/2` + `montar_catalogo/2` en el evento (sin remount) —
      un test real mostró que `push_patch` disparado desde una sesión
      YA conectada revienta con `UndefinedFunctionError` porque este
      módulo a propósito nunca define `handle_params/3` (se rompería el
      uso embebido en BC Motor si lo definiera) — ver `design.md` §1
      para el detalle completo del hallazgo.
- [x] A2. Nueva `restaurar_busqueda_picker/2`, llamada desde
      `mount(%{"recurso" => recurso} = params, ...)` con `params["q"]`
      — restaura `busqueda_catalogo_picker`/`resultados_catalogo_picker`
      desde la URL en vez de desde memoria de proceso.
- [x] A3. Confirmado (grep) que ningún otro `handle_event` de esta
      pantalla toca esos 2 assigns — no hizo falta corregir nada más.

## Grupo B — Comodín "\*" (R9) ✅

- [x] B1. Nuevo clause `Permissions.buscar_catalogos("*", limite)` +
      `query_catalogos/2` privada (factoriza el query que antes estaba
      inline). El clause `buscar_catalogos("", _limite), do: []` queda
      intacto.
- [x] B2. Bug real encontrado y arreglado en el camino (no estaba en el
      código original): un `dynamic/2` pineado dentro de un `and`
      armado a mano no es válido para Ecto en runtime
      (`Ecto.QueryError`, no lo agarra `mix compile`) — arreglado
      repitiendo `where:` como cláusula separada.

## Grupo C — Tests ✅

- [x] C1/C2. `test/metadata_app_web/live/sysadmin/
      catalogo_permisos_live_test.exs` (archivo nuevo, esta pantalla no
      tenía tests): elegir un catálogo con texto tipeado conserva el
      filtro después de `follow_redirect/2` (R4a); conceder un permiso
      (`toggle_permiso`) con el picker con texto tipeado tampoco lo
      vacía.
- [x] C4. `test/metadata_app/permissions_test.exs`: `"*"` lista
      catálogos sin substring y respeta `limite`; `""` sigue
      devolviendo `[]`.
- [x] C5. Recargar (nueva conexión `live/2`) sin `?q=` en la URL
      arranca con el picker vacío (R4b).
- C3 (URL después de `elegir_catalogo`) quedó cubierto implícitamente
  por C1 — no hizo falta un test aparte, ya que el enfoque final
  (query param) hace que el contenido del picker Y la URL dependan de
  la misma fuente.

## Grupo D — Verificación real ✅

- [x] D1. Suite completa corrida dentro de `devcontainer-app-1` —
      **634 tests (5 properties), 0 failures**.
- [x] D2. El flujo real que motivó el pedido queda cubierto por C1/C2:
      buscar → elegir catálogo → conceder permiso, picker intacto en
      cada paso.

## Grupo E — Bug real encontrado en dev (2026-09-17, fuera de alcance original)

Navegando en vivo con el comodín "*" (R9), el usuario encontró un
catálogo real (`consulta_croac_masterdata_clientes_baseclientes`, un
header `es_consulta:true` SIN fila `meta_schema_consulta` — dato
huérfano preexistente, sin relación con esta spec) que tumbaba la
pantalla entera con `KeyError`. El fix vive en el módulo COMPARTIDO
(`catalogo_permisos_live.ex`), documentado como R8a en
`SPEC-SYS-1109202605-bc-motor-tab-permisos-alcance` (la spec dueña de
ese comportamiento) — no se repite acá, solo se deja constancia de
dónde se encontró.

- [x] E1. `catalogo_base_de_consulta/1` ya no revienta con `nil` —
      degrada a un aviso en el render en vez de `KeyError`.
- [x] E2. Test nuevo (`catalogo_permisos_live_test.exs`): una Consulta
      huérfana no tumba la pantalla, muestra el aviso.
- [x] E3. Suite completa — **635 tests, 0 failures**.
