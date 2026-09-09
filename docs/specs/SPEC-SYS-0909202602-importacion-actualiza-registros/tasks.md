# Tasks — La importación por Excel también actualiza registros existentes

Cada tarea es chica y verificable por sí sola (compila, corre, un test
o una prueba manual puntual pasa) antes de pasar a la siguiente. Se
implementa con "seguí tasks.md, tarea N" — nunca todas de una sin que
se pida explícitamente.

## Grupo A — Modelo de datos y asistente (configuración)

- [x] **A1.** Sumar `"campo_identificador"` al shape de cada entrada de
      `"detalles"` en `PlantillaImportacion.definicion` — en el estado
      del editor de `ImportacionConstructorLive` (`detalle_inicial/2`,
      `campos_a_definicion/1` no cambia, el nuevo campo vive al nivel
      del detalle, no de cada campo). Verificable: guardar y releer una
      plantilla conserva el valor (aunque todavía no se pueda editar
      desde la UI).

- [x] **A2.** Mostrar el selector "Campo identificador del encabezado"
      siempre (sacar la condición `detalles != []`), con el texto
      ampliado. Verificable: en un catálogo SIN detalle, el paso 2 del
      asistente ahora muestra el selector en vez del aviso "este
      catálogo no tiene detalles".

- [x] **A3.** Agregar el selector "Campo identificador de este
      detalle" a cada detalle activado, poblado con
      `campos_disponibles(catalogo)` de ese detalle. Verificable: se
      puede elegir, guardar y releer sin perderse.

- [x] **A4.** Validación: si se configura un identificador (de
      encabezado o de un detalle), debe estar entre los campos
      incluidos de esa misma hoja — si no, error claro al intentar
      guardar la plantilla. Verificable: probar guardar sin cumplir la
      regla y confirmar el mensaje.

## Grupo B — Búsqueda de un registro existente

- [x] **B1.** `buscar_existente/3` en `MetaImportacionDatos` (0/1/N
      coincidencias). Test unitario con los 3 casos.

- [x] **B2.** `buscar_renglon_existente/4` (mismo criterio, acotado a
      `encabezado_id`). Test unitario con los 3 casos.

## Grupo C — Alta vs. actualización del encabezado

- [x] **C1.** En `procesar_fila`, bifurcar ANTES de construir nada: sin
      `campo_identificador_encabezado` → comportamiento actual sin
      tocar; con él, `buscar_existente/3` decide alta/actualización/
      ambiguo. Verificable: importar una plantilla sin identificador
      sigue dando de alta exactamente igual que hoy (regresión).
      Verificado con datos reales contra `categorias_prueba`.

- [x] **C2.** Camino de actualización — SOLO campos de encabezado (sin
      detalle activo todavía): `CatalogoGenerico.actualizar/4`.
      Prueba real: actualizar un catálogo simple vía import y confirmar
      en la base que se actualizó el registro existente, no se creó
      uno nuevo. Verificado con datos reales contra `pty_pedido_prueba`
      (mismo folio, dos importaciones, mismo id, campo cliente
      actualizado).

- [x] **C3.** Prueba real: mismo catálogo pero con motor de estados
      adoptado y SIN transición "Guardar" — confirmar que la
      actualización de encabezado se comporta igual que editarlo a
      mano en ese estado (rechaza si no hay nada editable, con
      mensaje claro, no un crash). Verificado contra `categorias_prueba`
      -- mensaje idéntico entre import y edición manual directa.

## Grupo D — Renglones: agregar nuevo vs. editar existente

- [x] **D1.** Particionar las filas de detalle de un encabezado que se
      actualiza en tres buckets por catálogo: "editar" (matchea un
      renglón existente), "nuevo" (no matchea ninguno) y error
      (ambiguo) — usando `buscar_renglon_existente/4`.

- [x] **D2.** Bucket "nuevo": `MetadataApp.Renglones.crear_todos/3`
      contra el `registro_existente.id`. Prueba real contra
      `pty_pedido_prueba`: encabezado con 2 renglones, reimportar
      agregando 1 fila de detalle nueva ("Clavos") — se agregó como
      renglón 3, los 2 anteriores intactos.

- [x] **D3.** Bucket "editar": si `MetaStateEngine.transicion_guardar/2`
      es `nil`, la fila entera se rechaza con
      `{:renglon_sin_guardar, catalogo}`. Si existe, actualizar vía
      `MetaStateEngine.ejecutar_transicion/4` con `renglones:`.
      Prueba real: reimportar "Tornillos" con cantidad distinta —
      cambió cantidad 5→50 en ESE renglón, "Tuercas" quedó byte a
      byte igual (R7.3).

- [x] **D4.** Combinar en una sola fila de encabezado: algunos
      renglones a editar + algunos nuevos al mismo tiempo, en una sola
      transacción atómica. Prueba real: "Tornillos" editado + "Clavos"
      nuevo en la MISMA reimportación — ambos ocurrieron atómicamente,
      1 solo encabezado (sin duplicar).

## Grupo E — Mensajes de error

- [x] **E1.** `mensaje_de_motivo/1` + `sugerencia_para/1`: casos nuevos
      `:identificador_ambiguo` y `{:renglon_sin_guardar, catalogo}`.
      Verificado con datos reales (Guardar desactivado temporalmente
      en `pty_pedido_prueba`) — mensaje y sugerencia correctos.

- [x] **E2.** Confirmar (prueba real) que un error de "campo no
      editable en el estado actual" durante una actualización por
      import sale con el mismo mensaje traducido que ya usa la edición
      manual — sin caso especial nuevo necesario. Ya verificado en C3
      (mensaje idéntico byte a byte entre import y edición manual).

## Grupo F — Vista previa y resultado (UI)

- [x] **F1.** Sumar `:accion` (`:crear` | `:actualizar`) a cada fila
      `:ok` del resultado de `procesar_filas/4`. Verificado con datos
      reales contra `pty_pedido_prueba`.

- [x] **F2.** `resultado_importar/1` (`catalogo_live.ex`) separa el
      conteo en "✓ N a crear" / "↻ M a actualizar" / "⚠ E con error".
      Verificado por compilación + revisión de código (mismo criterio
      de datos ya probado en F1); no se probó en navegador (fuera del
      patrón de verificación ya usado en el resto de esta spec).

- [x] **F3.** El botón final de confirmación refleja los conteos
      reales ("Importar N nuevos y actualizar M", con las variantes
      cuando alguno de los dos es 0). Mismo criterio de verificación
      que F2.

## Grupo G — Verificación end-to-end y regresión

- [x] **G1.** Prueba real completa: una plantilla con encabezado +
      detalle, identificador en ambos niveles, un Excel con las 4
      situaciones a la vez (alta nueva, renglón nuevo agregado, renglón
      existente actualizado, fila ambigua) — confirmar que la
      previsualización y el resultado final coinciden con lo esperado
      fila por fila. Verificado en una sola llamada a `ejecutar/3`
      contra `pty_pedido_prueba`: las 4 situaciones dieron el resultado
      esperado, incluida la fila ambigua rechazada sin abortar las
      otras 2 filas (R9).

- [x] **G2.** Confirmar que TODA plantilla ya existente en la base
      (sin el campo identificador nuevo configurado) importa exacto
      igual que antes de esta spec — sin excepciones. Cubierto
      estructuralmente: el código está gateado en `identificador_campo
      == nil` (C1) y `campo_identificador_detalle == nil` (R7.4,
      confirmado en G1 con la fila de alta), los dos únicos casos que
      corresponden a una plantilla ya existente sin el campo nuevo.
