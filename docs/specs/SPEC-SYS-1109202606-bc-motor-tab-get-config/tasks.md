# SPEC-SYS-1109202606 — BC Motor: Tab Get Config

**Documento:** Tasks · **Fase:** ✅ documentación retroactiva verificada + 1 fix real (Grupo D — código muerto eliminado, opción (b) elegida por el usuario) + 1 sección completa eliminada (Grupo E, 2026-09-12).

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

## Grupo E — Eliminación completa de "Filtros por default" ✅ (2026-09-12)

11. [x] A pedido del usuario ("la sección Filtros por default ya no
    tiene función"), se verificó impacto real antes de tocar código:
    0 catálogos con `filtro_default_fecha_modo` configurado en la
    base de dev, y `SPEC-SYS-0209202601-parametros-catalogo` ya cubre
    la misma necesidad de forma más flexible (ver `design.md` §5).
    Usuario confirmó proceder.
12. [x] Migración `20260912013436_quitar_filtro_default_fecha_de_header.exs`
    — dropea `filtro_default_fecha_modo`/`valor`/`valor_hasta` de
    `meta_schema_header`. Corrida en dev y test.
13. [x] `Header` (`meta_schema/header.ex`) — 3 `field` removidos del
    schema y del `cast/3` del changeset, comentarios reescritos.
14. [x] `MetadataAppWeb.FiltrosDefaultComponents` — archivo completo
    borrado (`filtros_default_components.ex`).
15. [x] `BcMotorLive` — import del módulo de arriba, render
    `<.panel_filtros_default>` y
    `handle_event("cambiar_filtro_fecha_modo", ...)` eliminados.
16. [x] `CatalogoLive` — `filtros_por_default/1` + su llamada, assign/
    badge `filtro_default_fecha_descripcion`, clave
    `"__fecha_registro__"` en `construir_filtros_ecto/2` y su
    condición en `datos_solicitados?/1`, todos eliminados.
17. [x] `FiltrosDefault.modos_fecha/0` eliminada (huérfana);
    `rango_fecha/3`/`descripcion/3`/`modos_fecha_rango/simple`
    verificados intactos (siguen sirviendo a Parámetros,
    `parametros_catalogo.ex:143`).
18. [x] `mix compile --force` limpio (dev y test, sin warnings
    nuevos). Migración corrida en dev Y test. `mix test`: 517 tests,
    0 failures — incluye `catalogo_live_filtros_test.exs` y los tests
    de Get Config, que montan los LiveViews completos.
19. [x] Hallazgo colateral documentado pero NO corregido (fuera de
    alcance): 2 columnas huérfanas en `meta_schema_consulta`
    (`filtro_fecha_catalogo`/`filtro_fecha_campo`) sin ningún
    consumidor real en `lib/` — ver `design.md` §5.

## Nota

A diferencia del hallazgo de
`SPEC-SYS-1109202602-bc-motor-tab-diagrama` (fix directo, sin
ambigüedad), el Grupo D fue una decisión real de producto — se le
preguntó al usuario antes de tocar código, eligió terminar de borrar
en vez de restaurar. El Grupo E fue un pedido directo del usuario,
pero igual se verificó impacto real (uso en base de datos, cobertura
por otra spec) antes de ejecutar el borrado.
