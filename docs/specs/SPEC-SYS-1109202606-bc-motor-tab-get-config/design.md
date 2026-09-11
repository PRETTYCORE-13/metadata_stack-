# SPEC-SYS-1109202606 — BC Motor: Tab Get Config

**Documento:** Design · **Fase:** ✅ aprobada (2026-09-11) — con 1 fix real (§6, R14): código muerto eliminado a pedido explícito del usuario, ver `tasks.md`.

Documentación retroactiva — `panel_get_view/1`, `panel_orden_resultados/1`,
`panel_campos_default/1` (`bc_motor_live.ex:2575-2851`) +
`FiltrosDefaultComponents.panel_filtros_default/1`
(`lib/metadata_app_web/live/filtros_default_components.ex`) +
`MetadataApp.FiltrosDefault` (contexto de cálculo de rangos de
fecha) + `Header.filtro_default_fecha_modo`/`cargar_todos_por_default`/
`orden_columnas_tabla`/`orden_resultados`.

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

## 5. Filtros por default — camino que SÍ funciona (R12-R14, parcial)

`FiltrosDefaultComponents.panel_filtros_default/1` ofrece los modos
de `FiltrosDefault.modos_fecha/0`:

```elixir
def modos_fecha do
  [
    {"", "Sin acotar"},
    {"actual", "Fecha actual"},
    {"mes_actual", "Mes actual completo"},
    {"mes_a_fecha", "Mes actual a la fecha"},
    {"anio_actual", "Año actual completo"},
    {"formula", "Fórmula"}
  ]
end
```

Los primeros 5 son dinámicos de verdad — `FiltrosDefault.rango_fecha/3`
tiene una cláusula propia para cada uno, recalculada contra
`Date.utc_today()` en cada consulta, sin depender de ningún valor
guardado. `"formula"` es el único que SÍ usa
`filtro_default_fecha_valor`/`valor_hasta` — pero como TEXTO de
fórmula (`FormulaFecha.parsear/1`), no como fecha literal; por eso su
UI real (no mostrada en el fragmento leído acá, pero coherente con
`cambiar_filtro_fecha_valor` aceptando cualquier string) no son los
`<input type="date">` que sí se ven en el bloque de abajo.

`cambiar_filtro_fecha_modo`/`cambiar_filtro_fecha_valor` (R14) — al
cambiar de modo, limpia siempre `filtro_default_fecha_valor`/
`valor_hasta`, sin importar el modo nuevo.

## 6. Fix real — modo "rango" era código muerto, eliminado

`panel_filtros_default/1` (línea 52) tiene una rama completa
(selectores de fecha "Desde"/"Hasta", `<input type="date">` +
`AbrirCalendario`) condicionada a `@header.filtro_default_fecha_modo
== "rango"` — pero **`"rango"` no es ninguno de los 6 valores que
`FiltrosDefault.modos_fecha/0` ofrece como botón** (ver §5): no hay
ningún control en la UI actual que pueda dejar ese campo en
`"rango"`. Se buscó en todo `lib/` cualquier otro lugar que asigne
ese valor — no aparece ninguno.

Más aún: **`FiltrosDefault.rango_fecha/3` tampoco tiene una cláusula
para `"rango"`** — sus cláusulas cubren
`"actual"`/`"mes_actual"`/`"mes_a_fecha"`/`"anio_actual"`/
`"primer_dia_mes"`/`"primer_dia_anio"`/`"formula"`, y termina en un
catch-all `rango_fecha(_modo, _valor, _valor_hasta), do: nil`. Si
`"rango"` SE HUBIERA guardado por algún camino externo (ej. un dato
migrado de una versión anterior de este campo, o escrito a mano), el
resultado sería "sin acotar" de todas formas — la funcionalidad ni
siquiera está implementada del lado del cálculo.

El comentario de diseño en `Header` (`meta_schema/header.ex:23-36`)
SÍ describe `"rango"` como una opción real e intencional ("por
diseño, un rango es un par de fechas puntuales elegidas a propósito,
no un período relativo a 'hoy'") junto con otros nombres de modo
(`"primer_dia_anio"`, `"ultimo_dia_anio"`) que TAMPOCO coinciden 1:1
con los 6 valores reales de `modos_fecha/0` hoy — todo apunta a que
`FiltrosDefault` se refactorizó/renombró en algún momento (
probablemente al construirse `SPEC-SYS-0209202601`, que reusa/expande
este mismo vocabulario de modos de fecha para Parámetros) sin
actualizar ni el comentario de `Header` ni la rama de UI de "rango"
en `panel_filtros_default.ex`, que quedó huérfana.

**Resuelto**: consultado el usuario entre restaurar `"rango"` de
verdad o terminar de borrar la rama muerta, eligió borrar — quitada
la rama de UI en `panel_filtros_default/1`, el
`handle_event("cambiar_filtro_fecha_valor", ...)` (su único emisor
real) y corregido el comentario de `Header` para que ya no describa
un modo que nunca funcionó. Ver `tasks.md` Grupo D.

## 7. Fuera de alcance

Igual que `requirements.md` §6.
