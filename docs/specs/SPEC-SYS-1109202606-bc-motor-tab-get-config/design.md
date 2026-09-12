# SPEC-SYS-1109202606 — BC Motor: Tab Get Config

**Documento:** Design · **Fase:** ✅ aprobada (2026-09-11) — con 1 fix real (§6, R14): código muerto eliminado a pedido explícito del usuario, ver `tasks.md`. **2026-09-12**: §5 completa ("Filtros por default") ELIMINADA del código a pedido explícito del usuario — ver §5 reescrita y `tasks.md` Grupo E.

Documentación retroactiva — `panel_get_view/1`, `panel_orden_resultados/1`,
`panel_campos_default/1` (`bc_motor_live.ex:2575-2851`) +
`Header.cargar_todos_por_default`/`orden_columnas_tabla`/`orden_resultados`.
`MetadataApp.FiltrosDefault` (contexto de cálculo de rangos de fecha)
sigue existiendo — ahora exclusivo de
`SPEC-SYS-0209202601-parametros-catalogo`, ver §5.

## 1. Visibilidad (R1)

`%{key: "getview", label: "Get Config"}` vive en el bloque
INCONDICIONAL de tabs (`bc_motor_live.ex:2044-2047`, junto a
Relaciones/Post Config) — a diferencia de Estados/Transiciones/
Diagrama/Contrato/Permisos, ningún `unless(@es_detalle?, ...)` lo
envuelve. Coherente con R9 de
`catalogo-maestro-detalle-requerimientos.md`: un catálogo detalle
tiene sus propios metacampos, y por lo tanto su propia vista de
tabla.

## 2. Grilla unificada de columnas (R2-R7)

`filas_get_view/2` (`bc_motor_live.ex:2755-2809`) combina dos
orígenes en una sola lista:

- **Control**: `@campos_control` (`bc_motor_live.ex:54-64`), lista
  fija de 9 descriptores (`clave`, `etiqueta`, `visible_key` — el
  campo booleano real en `Header` — y `requiere_alcance?`), filtrada
  con `Enum.reject(&(&1.requiere_alcance? and not
  header.alcance_habilitado))` (R3) — Empresa/Sucursal/Almacén/
  Unidad de venta solo existen como columna física cuando Alcance de
  Datos está activo (`alcance_field_asts/1` en
  `MetaCatalogoGenerico`).
- **Negocio**: `@campos` mapeados 1:1, con un caso especial:
  `"fecha_registro"` tiene fila en `meta_schema_detail` (para poder
  aparecer/ordenarse acá) pero se etiqueta `tipo_columna: :control`
  igual — es un campo de sistema que el servidor pisa solo, aunque
  estructuralmente viva junto a los campos de negocio.

Ambos grupos se intercalan: `id` primero, luego negocio, luego el
resto de control (`{id_control, resto_control} =
Enum.split_with(control, &(&1.clave == "id"))` +
`id_control ++ negocio ++ resto_control`) — mismo orden visual que
ya tenía `CatalogoLive` antes de unificar esta grilla. El orden final
real se sobreescribe con `Header.orden_columnas_tabla` si existe
(`Enum.sort_by` con índice, `Enum.sort_by/2` es estable — los
empates, o sea cualquier columna nueva que el catálogo nunca tocó
todavía en esta grilla, no cambian de posición relativa entre sí,
quedan al final en su orden natural).

**Reordenar (R5)**: mismo hook `ListaOrdenable` que la grilla de
Campos (ver `SPEC-SYS-1109202601`), `data-grupo="campos-catalogo-getview-unificado"`
— grupo DISTINTO, así Sortable.js nunca mezcla un drag de esta tabla
con el de la tabla de Campos aunque ambas usen el mismo hook.

**Guardar (R4, R7)**: `handle_event("guardar_get_view", params,
socket)` — dos listas de nombres marcados (`visibles[]` para negocio,
`visibles_control[]` para control, distinguidos por
`name={if fila.flag_header?, do: "visibles_control[]", else:
"visibles[]"}` en el checkbox). Actualiza TODOS los campos de negocio
en un `Enum.reduce_while` (corta al primer error) y, si eso salió
bien, los 9 booleanos de control en un solo `MetaSchemaContext.actualizar_header/2`
— dos escrituras agrupadas (una por campo de negocio + una para todo
control), nunca una escritura por checkbox individual tocado.
"Seleccionar todos"/"Deseleccionar todos" (R4) son `onclick` puro en
el cliente sobre los checkboxes del `<form>` — no tocan el servidor
hasta el submit real.

Parámetros/Totales por columna (R6) — `celda_totales`/`toggle_es_parametro`/
`celdas_parametro` de `ParametrosCatalogoComponents`, mismo mecanismo
documentado en `SPEC-SYS-0209202601-parametros-catalogo`, reusado tal
cual dentro de esta misma fila de la grilla (`campo_param` arma el
shape `%{"catalogo" => ..., "campo" => ...}` que ese componente
espera).

## 3. Orden de resultados (R8-R10)

`panel_orden_resultados/1` opera sobre `Header.orden_resultados`
(lista de `%{"campo" => ..., "direccion" => "asc"|"desc"}`) — cada
entrada con botones "↑"/"↓" (`mover_orden_resultados`, deshabilitados
en los extremos de la lista) y "×" (`quitar_orden_resultados`), más
un botón de dirección que alterna asc/desc (`cambiar_direccion_orden_resultados`).
Cada acción persiste de inmediato (sin "Guardar" aparte para esta
sección) — consistente con el resto de toggles inmediatos del BC
Motor. R10 (el usuario final puede reordenar después) es
comportamiento de `CatalogoLive`, fuera de este tab — se documenta
acá solo como aclaración de que esto es un PUNTO DE PARTIDA, no una
restricción.

## 4. Campos por default (R11)

`panel_campos_default/1` — un solo botón toggle sobre
`Header.cargar_todos_por_default` (`toggle_cargar_todos_por_default`).
Semántica real en `CatalogoLive.datos_solicitados?/1` (fuera de esta
spec): con el flag activo, la tabla no espera ningún filtro/búsqueda
para traer datos.

## 5. Filtros por default — ELIMINADO 2026-09-12

Hasta esta fecha, `FiltrosDefaultComponents.panel_filtros_default/1`
ofrecía un interruptor de modo (`FiltrosDefault.modos_fecha/0`: "",
"actual", "mes_actual", "mes_a_fecha", "anio_actual", "formula") que
`CatalogoLive.filtros_por_default/1` traducía a un filtro real sobre
`fecha_registro`, aplicado automáticamente al abrir la tabla — con un
fix real ya documentado antes de esta reescritura: un séptimo modo,
`"rango"` (fecha fija con dos calendarios), era código muerto —
ningún botón lo activaba ni `rango_fecha/3` lo implementaba — y se
eliminó su rama de UI el 2026-09-11 (R14, ver `tasks.md` Grupo D).

**Eliminado por completo el 2026-09-12**, a pedido explícito del
usuario, tras verificar dos cosas contra la base real y el código:

1. Ningún catálogo tenía `filtro_default_fecha_modo` configurado (0
   filas en `meta_schema_header`) — a diferencia del caso de "rango"
   (§ anterior), acá no había ni siquiera un caso de uso activo que
   proteger.
2. `SPEC-SYS-0209202601-parametros-catalogo` ya resuelve la misma
   necesidad de forma estrictamente más amplia: cualquier campo Fecha
   de negocio marcado `"es_parametro"` (no solo la columna de sistema
   `fecha_registro`) puede tener el mismo tipo de default dinámico,
   con el usuario final pudiendo ajustarlo desde el panel de filtros
   — Parámetros reusa el MISMO motor de cálculo
   (`ParametrosCatalogo.aplicar_filtros_fecha_estandar/4` llama a
   `FiltrosDefault.rango_fecha/3`, línea `parametros_catalogo.ex:143`),
   así que no se perdió ninguna capacidad de cálculo, solo la UI/
   columnas de Header que la exponían a nivel catálogo completo.

**Qué se borró** (código, no solo UI):

- `Header.filtro_default_fecha_modo`/`valor`/`valor_hasta` — 3
  columnas físicas de `meta_schema_header`, dropeadas por migración
  (`20260912013436_quitar_filtro_default_fecha_de_header.exs`).
- `MetadataAppWeb.FiltrosDefaultComponents` — módulo completo borrado
  (`lib/metadata_app_web/live/filtros_default_components.ex`), solo
  tenía esta función.
- `BcMotorLive`: el import del módulo de arriba, el render
  `<.panel_filtros_default header={@header} />`, y
  `handle_event("cambiar_filtro_fecha_modo", ...)`.
- `CatalogoLive`: `filtros_por_default/1`, su llamada en
  `montar_catalogo/2`, el assign/badge morado
  `filtro_default_fecha_descripcion`, la clave especial
  `"__fecha_registro__"` en `construir_filtros_ecto/2`, y su condición
  en `datos_solicitados?/1` (una tabla sin `cargar_todos_por_default`
  activo y sin este filtro ya NO tenía otra forma de auto-cargar datos
  al abrir salvo búsqueda/Parámetros — comportamiento sin cambio
  observable porque ningún catálogo real dependía de esta rama).
- `FiltrosDefault.modos_fecha/0` — quedó huérfana (era exclusiva del
  panel borrado), se eliminó. `rango_fecha/3`, `descripcion/3`,
  `modos_fecha_rango/0`, `modos_fecha_simple/0` NO se tocaron — los
  sigue usando Parámetros activamente.

**Hallazgo colateral, fuera de alcance**: `meta_schema_consulta` tiene
2 columnas huérfanas (`filtro_fecha_catalogo`/`filtro_fecha_campo`,
migración `20260826182124`) que su propio comentario describe como
"reusa tal cual" los campos de `Header` que se acaban de borrar —
pero ningún código real las lee ni las escribe (grep sin resultados
en todo `lib/`). Parece un primer intento de filtro por fecha para
Consulta, abandonado al día siguiente cuando se rediseñó Parámetros
(2026-08-27). No se tocó: es otra tabla, otro catálogo, no forma
parte de esta spec — candidato a un fix propio si hace falta.

Verificado: `mix compile --force` limpio (dev y test, mismos warnings
preexistentes de siempre, ninguno nuevo), migración corrida en dev Y
test, `mix test`: 517 tests, 0 failures — incluye
`catalogo_live_filtros_test.exs` y los tests de Get Config
(`bc_motor_live_orden_resultados_test.exs`,
`bc_motor_live_parametros_test.exs`), que montan estos LiveViews
completos y hubieran fallado con `KeyError` si algún assign hubiera
quedado colgando.

## 7. Fuera de alcance

Igual que `requirements.md` §6.
