# Requirements — Despublicar un catálogo huérfano de un ambiente

## Contexto

Hoy existen dos mecanismos para reflejar un borrado en un ambiente
desplegado: `mix motor.despublicar` (necesita que "Eliminar" en BC List
haya dejado una migración de `DROP`) y `mix endpoint.despublicar`
(específico de Endpoints, con su propio tombstone,
`SPEC-SYS-1009202602`). Ninguno cubre el caso real encontrado hoy: un
catálogo que en un ambiente desplegado quedó como header + tabla
física **sin ningún rastro local** — nunca pasó por "Eliminar", así
que no hay migración de `DROP` que reusar.

**Caso real que motivó esto:** `"historico"` existe en `unstable`
(header + tabla física con datos reales), no existe en NINGÚN lado
local (ni header, ni `.ex`, ni migración) — se renombró en el mismo
registro a `pty_h_historico` en vez de crear uno nuevo y borrar el
viejo. Además comparte `schema_context_nav` (`/historico`) con
`pty_h_historico`, lo que causa un error real
(`Ecto.MultipleResultsError`) al navegar esa ruta. Puede repetirse con
cualquier rename futuro.

## Requisitos

**R1.** CUANDO un administrador indique el nombre de un catálogo que
ya no existe local, EL SISTEMA DEBE poder eliminarlo (metadata Y tabla
física) de un ambiente desplegado elegido, sin requerir que exista una
migración de `DROP` generada de antemano.

**R2.** EL SISTEMA DEBE exigir un ambiente destino explícito, nunca un
default — mismo criterio que `motor.publicar`/`motor.despublicar`/
`endpoint.despublicar`.

**R3.** CUANDO el catálogo indicado SÍ exista local todavía, EL
SISTEMA DEBE rechazar la operación con un mensaje explícito — para eso
ya está "Eliminar" en BC List + `motor.despublicar`.

**R4.** CUANDO el catálogo indicado tampoco exista en el ambiente
destino, EL SISTEMA DEBE responder de forma idempotente (avisar que no
había nada que borrar, nunca fallar) — mismo criterio que
`endpoint.despublicar`.

**R5.** EL SISTEMA DEBE pedir confirmación explícita antes de ejecutar
(por lo destructivo/irreversible de la operación) — mismo criterio que
"Eliminar" en BC List (tipear el nombre exacto).
