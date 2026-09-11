# SPEC-SYS-1109202606 — BC Motor: Tab Get Config

**Documento:** Tasks · **Fase:** ✅ documentación retroactiva verificada + 1 fix real (Grupo D — código muerto eliminado, opción (b) elegida por el usuario).

## Grupo A — Visibilidad y grilla unificada ✅

1. [x] R1 verificado: "getview" en el bloque incondicional de tabs
   (`bc_motor_live.ex:2044-2047`).
2. [x] R2-R7 verificados contra `filas_get_view/2`
   (`:2755-2809`), `handle_event("guardar_get_view", ...)`
   (`:999-1028`) y `@campos_control` (`:54-64`).

## Grupo B — Orden de resultados y Campos por default ✅

3. [x] R8-R10 verificados contra `panel_orden_resultados/1`.
4. [x] R11 verificado contra `panel_campos_default/1` +
   `toggle_cargar_todos_por_default`.

## Grupo C — Filtros por default (camino funcional) ✅

5. [x] R12/R13 verificados contra `FiltrosDefault.modos_fecha/0` (6
   valores reales) y `cambiar_filtro_fecha_modo`
   (`bc_motor_live.ex:897-910`).

## Grupo D — Fix real: código muerto del modo "rango" ✅

6. [x] Decisión del usuario: opción (b) — terminar de borrar la rama
   muerta, no restaurarla.
7. [x] `FiltrosDefaultComponents.panel_filtros_default/1` — quitada
   la rama `if @header.filtro_default_fecha_modo == "rango"` (los
   dos `<input type="date">` desde/hasta) y actualizado el moduledoc.
8. [x] `BcMotorLive.handle_event("cambiar_filtro_fecha_valor", ...)`
   eliminado (su único emisor real era la rama borrada) — comentario
   de `cambiar_filtro_fecha_modo` actualizado para reflejar los 6
   modos reales.
9. [x] `Header` (`meta_schema/header.ex`) — comentario de
   `filtro_default_fecha_modo`/`valor`/`valor_hasta` corregido para
   ya no describir "rango" como si funcionara.
10. [x] `mix compile --force` limpio (dev y test), `mix test`: 517
    tests, 0 failures. Servidor reiniciado y confirmado arriba.

## Nota

A diferencia del hallazgo de
`SPEC-SYS-1109202602-bc-motor-tab-diagrama` (fix directo, sin
ambigüedad), acá había una decisión real de producto — se le
preguntó al usuario antes de tocar código, eligió terminar de borrar
en vez de restaurar.
