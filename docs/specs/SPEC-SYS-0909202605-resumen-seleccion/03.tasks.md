# Tasks — Resumen de selección

Cada tarea es chica y verificable por sí sola (compila, corre, un test
o una prueba manual puntual pasa) antes de pasar a la siguiente. Se
implementa con "seguí tasks.md, tarea N" — nunca todas de una sin que
se pida explícitamente.

## Grupo A — Selección de registros (estado + UI mínima)

- [x] **A1.** Assign nuevo `@seleccionados` (`MapSet.new()`) en el
      `mount`/`handle_params` de `CatalogoLive`, para catálogo y
      Consulta. Verificable: compila, el valor inicial es un `MapSet`
      vacío en los dos casos.

- [x] **A2.** Columna de casillero en el template del catálogo normal
      (`render/1` default): `<th>` con checkbox de "seleccionar
      página" en el `<thead>`, `<td>` con checkbox por fila en el
      `<tbody>` (atado a `toggle_seleccion_fila`), celda vacía extra en
      el `<tfoot>` para mantener alineación. Verificado con
      `Phoenix.LiveViewTest` real (`catalogo_live_resumen_seleccion_test.exs`).

- [x] **A3.** Mismo casillero en el template de Consulta (`render/1`
      con `es_consulta?: true`) — mismo evento, misma forma de assign.
      **Bug real encontrado y corregido acá**: `fila.id` no existía en
      el mapa de una fila de Consulta salvo que el admin hubiera
      marcado "id" como columna de control visible (`MetaConsultas.
      resolver_campos_control/3`) — crasheaba con `KeyError` al abrir
      cualquier Consulta sin esa columna. Se corrigió
      `MetaConsultas.ejecutar/6` para incluir SIEMPRE el `id` del
      catálogo base en cada fila (clave átomo `:id`, nunca choca con
      una clave de columna real porque esas van namespaced
      `catalogo__campo`). Verificado con datos reales
      (`catalogo_live_consulta_test.exs`, que además detectó el bug al
      correr con el checkbox nuevo).

- [x] **A4.** Checkbox "seleccionar todos los visibles" en el `<th>` de
      cabecera (marcado si `todos_seleccionados_en_pagina?/2` da
      `true`) + `handle_event("toggle_seleccion_pagina", ...)`, en
      ambos templates. Verificable: tildarlo selecciona toda la
      página; volver a tildarlo la deselecciona; no toca selección de
      otras páginas.

- [x] **A5.** Acción "Limpiar selección" (botón chico, se agrega junto
      a la barra de resumen en el Grupo E, pero el evento se cablea
      ahora) + `handle_event("limpiar_seleccion", ...)`. Verificable:
      vacía `@seleccionados` sin importar cuántas páginas se
      visitaron.

- [x] **A6.** R5 — los handlers que cambian filtros, búsqueda, orden o
      parámetros (`aplicar_filtro`, `quitar_filtro`,
      `buscar_general`, `ordenar_por_columna`, cambio de parámetro,
      cambio de plantilla de Consulta) agregan
      `assign(:seleccionados, MapSet.new())` a su salida. Los handlers
      de PAGINACIÓN no se tocan. Verificado con
      `Phoenix.LiveViewTest` real: seleccionar algo, cambiar un
      filtro, confirmar que la selección se vació; seleccionar algo,
      cambiar de página, confirmar que la selección SIGUE ahí.

## Grupo B — Cálculo del resumen (backend)

- [x] **B1.** `CatalogoGenerico.agregar_seleccionados/4` (acotado solo
      por `id in ids` + alcance de datos, nunca por filtros/búsqueda/
      parámetros de la vista). Test unitario: con 3 registros reales,
      seleccionar 2 por id y confirmar SUMA/PROMEDIO/MÍNIMO/MÁXIMO/
      CONTEO correctos sobre esos 2 nada más. 7/7 tests, incluidos
      lista vacía (`nil`) y registro dado de baja (ignorado).

- [x] **B2.** `MetaConsultas.agregar_seleccionados/5` (mismo criterio,
      resolviendo el alias de la tabla base de la Consulta — la firma
      final necesita `scope` además de `consulta`, ver corrección en
      design.md). Test unitario con un join real
      (`meta_fixture_cliente` + `meta_fixture_equipo`) confirmando que
      el alias correcto es el de la tabla BASE. **2 bugs reales
      encontrados y corregidos acá**: (1) `t.id` con un alias
      interpolado (`^alias_base`) no es válido en Ecto — hace falta
      `field(t, :id)`, igual que ya usa el resto del archivo; afectaba
      también al fix de A3 en `ejecutar/6`. (2) `MetaConsultas.agregar/6`
      existente nunca aplica alcance de datos (gap real preexistente,
      fuera de esta spec, documentado en el código pero no corregido).
      De paso, se restauró en la base de test la metadata de
      `meta_fixture_equipo` (faltaba igual que `meta_fixture_cliente`),
      lo que además arregló 4 tests preexistentes de "motor
      multi-tabla" que estaban rotos por la misma causa.

- [x] **B3.** `CatalogoLive.recalcular_resumen_seleccion/1` (una query
      por campo con `resumen_seleccion_activo == true`, resultado en
      `@resumen_seleccion_valores`) — se invoca al final de
      `toggle_seleccion_fila`, `toggle_seleccion_pagina` y (poniendo
      `%{}` directo, sin consultar nada) `limpiar_seleccion`; también
      se limpia junto con `@seleccionados` en los handlers de R5.
      Verificado: sin ningún campo configurado todavía (Grupo C aún no
      existe), los 18 tests de LiveView de A2-A6 siguen pasando sin
      error tras la selección disparar la recalculación en cada click.

## Grupo C — Configuración por campo (sysadmin)

- [x] **C1.** Sumar el chip `Sel` a `celda_totales/1`
      (`parametros_catalogo_components.ex`), togglea
      `resumen_seleccion_activo` en `schema_context_properties`/
      elemento de `Consulta.campos`. Verificable: aparece junto a
      `Tot`/`Mín/Máx`/`Pág`/`Gral`, sin romper esos otros chips.

- [x] **C2.** Mini-form función (Suma/Promedio/Mínimo/Máximo/Conteo) +
      etiqueta, visible solo cuando `Sel` está activo →
      `resumen_seleccion_funcion`/`resumen_seleccion_etiqueta`.
      Verificable: guardar y releer conserva los 2 valores.

- [x] **C3.** Implementar los `handle_event` de C1/C2
      (`cambiar_resumen_seleccion_activo`,
      `cambiar_resumen_seleccion_funcion`,
      `cambiar_resumen_seleccion_etiqueta`) en `bc_motor_live.ex`,
      igual que ya existen `cambiar_total_general`/
      `cambiar_agregacion_activa`. Verificado con datos reales
      (`bc_motor_live_parametros_test.exs`): Sel activo, función,
      etiqueta y Totales (`agregacion_activa`) siguen independientes.

- [x] **C4.** Mismos 3 `handle_event` en `consulta_editor_live.ex`
      (mutación del elemento correspondiente de `Consulta.campos` +
      guardado del array completo, mismo criterio que
      `cambiar_total_general` ahí). Verificado con datos reales
      (`consulta_editor_live_test.exs`).

- [x] **C5.** Cambiar la condición de aparición del mini-form de
      máscara (separador/símbolo) de `agregacion_activa` a
      `agregacion_activa or resumen_seleccion_activo`. Verificable:
      un campo con SOLO `Sel` activo (sin `Tot`) ahora también puede
      configurar separador/símbolo.

- [x] **C6.** Sumar `formato_unidad` (input de texto) y
      `formato_porcentaje` (chip toggle, no checkbox -- mismo patrón
      visual que Mín/Máx/Pág/Gral) al mini-form de máscara +
      `handle_event` `cambiar_formato_unidad`/`cambiar_formato_porcentaje`
      en `bc_motor_live.ex` Y `consulta_editor_live.ex`. Verificado con
      datos reales en ambos LiveViews, en los mismos tests de C3/C4.

**Nota (2026-09-09):** de paso se encontró y corrigió otra brecha real
de infraestructura de test: `meta_schema_permiso` estaba completamente
vacía en la base de test (0 de 103 filas de dev) — bloqueaba el acceso
a CUALQUIER pantalla `/sysadmin/*` en tests (incluidas las de C3/C4).
Restaurada desde dev. Bajó la cantidad de fallas preexistentes no
relacionadas de 81 a 20 en la suite completa.

## Grupo D — Formato de los indicadores

- [x] **D1.** `formatear_indicador_resumen/2` en `catalogo_live.ex`
      (porcentaje → agrega "%"; unidad → agrega el texto después del
      número; si ninguno de los dos, cae al símbolo/separador ya
      existentes vía `aplicar_simbolo/2`) — deliberadamente duplica el
      dispatch de `formatear_agregacion/2` en vez de modificarla, para
      no arriesgar el formato ya en producción de Total general y de
      cada celda de dato. Verificado con datos reales junto con E1-E3
      (caso "20 años" con `formato_unidad`).

## Grupo E — Barra de Resumen de selección (UI)

- [x] **E1.** Componente `resumen_seleccion/1`: pill compacto en una
      sola línea ("`N seleccionados · Etiqueta valor · ...`"), con
      apariencia distinta a los botones de acción de la barra (fondo
      azul vs. gris — R18), y el botón "Limpiar" de A5.

- [x] **E2.** Insertarlo en la banda de acciones superior de AMBOS
      templates, gateado por `MapSet.size(@seleccionados) > 0`.
      Verificado con datos reales: aparece al seleccionar el primer
      registro ("1 seleccionado"), desaparece al limpiar (R7/R8).

- [x] **E3.** Prueba real (`Phoenix.LiveViewTest`, no navegador —
      mismo criterio que el resto de esta spec): catálogo con SUMA
      configurada en un campo con etiqueta propia y otro con
      `formato_unidad` — confirmado que el texto se actualiza al
      instante con cada selección/deselección, con la SUMA correcta
      calculada exclusivamente sobre lo seleccionado (probado contra
      un registro NO seleccionado con un valor muy distinto, para
      descartar que se cuele en el cálculo) y el formato de unidad
      aplicado ("20 años").

## Grupo F — Verificación end-to-end y regresión

- [x] **F1.** Prueba real completa: catálogo con Resumen de selección
      configurado en 2+ campos — seleccionar registros en la página 1,
      pasar a la página 2 y seleccionar más, confirmar que el resumen
      suma TODO lo seleccionado (no solo la página actual); cambiar un
      filtro y confirmar que la selección y el resumen se vacían. 26
      registros reales, página 1 + página 2, suma 10.00+10.00=20.00
      confirmada tras cambiar de página (no solo el contador).

- [x] **F2.** Prueba real en una Consulta con al menos un join —
      mismo criterio que F1, confirmando que el cálculo usa la tabla
      BASE de la Consulta para el `id`, no una tabla joineada. **Bug
      real encontrado y corregido acá**: `@claves_totales_consulta`
      (catalogo_live.ex) nunca se actualizó con las 5 claves nuevas de
      esta spec -- sin eso, `columna_desde_campo_consulta/2` las
      descartaba en silencio para TODA Consulta (no solo con join); la
      config de Grupo C quedaba guardada en la base pero nunca llegaba
      a `@columnas`, así que la barra nunca mostraba nada en una
      Consulta. El test de C4 no lo detectó porque solo verificaba la
      persistencia cruda, no el camino de renderizado -- F2 sí, al
      probar el flujo completo end-to-end.

- [x] **F3.** Confirmar (prueba real) que "Total general", "Mín/Máx
      recomendado" y "Total de página" siguen mostrando exactamente
      los mismos valores que antes de esta spec, sin importar qué
      esté seleccionado — el Resumen de selección nunca los altera
      (R10/R15). Verificado con los 4 mecanismos activos a la vez
      sobre el mismo campo: seleccionar 1 de 2 registros no movió el
      Total general (150.00, suma de los 2), mientras el Resumen de
      selección mostraba su propio valor aparte.
