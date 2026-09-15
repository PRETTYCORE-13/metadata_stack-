# Requirements — Resumen de selección

## Contexto

Hoy, al ver un listado (catálogo) o una Consulta (Reporte), la plataforma
ya muestra un "Total general" (suma sobre TODOS los registros que
cumplen los filtros/búsqueda activos) y otras variantes ("Total de
página", "Mín/Máx recomendado"). Ninguno de estos permite responder una
pregunta distinta y muy común: *"de estos pocos registros que elegí a
mano, ¿cuánto suman?"* — por ejemplo, marcar 3 pedidos puntuales y ver
cuánto suman en total antes de imprimirlos o procesarlos.

**Hallazgo de la investigación previa (2026-09-09):** hoy NO existe
ningún mecanismo de selección de filas (casillero por registro) ni
ninguna acción masiva ("Imprimir seleccionados", "Marcar como",
"Capturar pagos") en la tabla de un listado ni de una Consulta — se
verificó exhaustivamente en `catalogo_live.ex` y no hay rastro. La idea
original mencionaba estas acciones como si ya existieran; a pedido
explícito, esta spec construye el mecanismo de selección MÍNIMO
necesario para que el Resumen de selección funcione (casillero por
fila + contador), pero NO diseña ninguna acción masiva — eso queda
fuera de alcance, para una spec aparte.

El motor de agregación (SUMA/PROMEDIO/MÍNIMO/MÁXIMO/CONTEO) ya existe y
se reusa igual para catálogos y Consultas — lo que falta es un segundo
"modo" de cálculo: en vez de "sobre todo lo filtrado", "sobre lo que el
usuario seleccionó a mano".

## Requisitos

### Selección de registros (base mínima nueva)

**R1.** EL SISTEMA DEBE permitir seleccionar y deseleccionar cada
registro de un listado o Consulta de forma individual, mediante un
casillero visible en su fila.

**R2.** EL SISTEMA DEBE ofrecer una forma de seleccionar o deseleccionar
de una sola vez todos los registros visibles en la página actual.

**R3.** CUANDO el usuario cambie de página sin deseleccionar nada, EL
SISTEMA DEBE conservar la selección de las páginas ya visitadas — el
conteo y el Resumen de selección deben seguir contando esos registros
aunque ya no estén a la vista.

**R4.** EL SISTEMA DEBE ofrecer una forma de limpiar toda la selección
de una sola vez.

**R5.** CUANDO el usuario cambie los filtros, la búsqueda o el orden de
la vista, EL SISTEMA DEBE limpiar la selección — una selección hecha
sobre un conjunto de datos no debe sobrevivir silenciosamente a un
cambio de qué datos se están mirando.

**R6.** Esta spec NO DEBE agregar ninguna acción masiva (imprimir,
marcar como, capturar pagos, ni ninguna otra) sobre los registros
seleccionados — solo el mecanismo de selección y su Resumen.

### Resumen de selección — visibilidad y contenido

**R7.** CUANDO exista al menos un registro seleccionado, EL SISTEMA
DEBE mostrar en la barra superior de la pantalla un Resumen de
selección con, como mínimo, la cantidad de registros seleccionados.

**R8.** CUANDO no exista ningún registro seleccionado, EL SISTEMA DEBE
ocultar por completo el Resumen de selección.

**R9.** CUANDO el usuario seleccione o deseleccione cualquier registro
(en cualquier página), EL SISTEMA DEBE recalcular y actualizar de
inmediato el Resumen de selección, sin recargar la pantalla.

**R10.** EL SISTEMA DEBE calcular cada indicador del Resumen de
selección ÚNICAMENTE sobre los registros seleccionados — nunca sobre el
total general filtrado ni sobre la página actual. El Resumen de
selección y el "Total general" ya existente son cálculos independientes
y pueden convivir en pantalla mostrando números distintos al mismo
tiempo.

**R11.** EL SISTEMA NO DEBE mostrar en el Resumen de selección ningún
campo que no haya sido configurado explícitamente para aparecer ahí.

### Configuración por catálogo/Consulta

**R12.** EL SISTEMA DEBE permitir configurar, para cualquier catálogo o
Consulta, qué campos numéricos participan del Resumen de selección.

**R13.** EL SISTEMA DEBE permitir elegir, para cada campo configurado,
una operación entre: SUMA, PROMEDIO, MÍNIMO, MÁXIMO o CONTEO.

**R14.** EL SISTEMA DEBE permitir configurar una etiqueta propia para
cada campo del Resumen de selección (independiente del nombre de columna
que ese campo usa en la tabla).

**R15.** Esta configuración DEBE poder aplicarse tanto a un catálogo
(listado) como a una Consulta (Reporte), con el mismo criterio para
ambos.

### Formato de los indicadores

**R16.** EL SISTEMA DEBE mostrar cada indicador respetando el formato
configurado del campo — moneda (con símbolo), cantidad (con una unidad
de texto libre, ej. "cajas", "kg"), porcentaje, o número simple con
separador de miles — igual que ya se respeta el formato en el resto de
la plataforma (tablas, Total general).

**R16.1.** CUANDO un campo esté configurado como moneda, EL SISTEMA
DEBE mostrar el indicador con el símbolo de moneda configurado.

**R16.2.** CUANDO un campo esté configurado como cantidad con unidad, EL
SISTEMA DEBE mostrar el indicador seguido del texto de esa unidad (ej.
"12 cajas").

**R16.3.** CUANDO un campo esté configurado como porcentaje, EL SISTEMA
DEBE mostrar el indicador con el símbolo "%".

### Presentación visual

**R17.** EL SISTEMA DEBE mostrar los indicadores del Resumen de
selección de forma compacta, en una sola línea, ocupando el mínimo
espacio posible en la barra superior (ej. "3 seleccionados · Total
$2,282.00 · 12 cajas · Descuento $150.00").

**R18.** EL SISTEMA DEBE mostrar el Resumen de selección con una
apariencia visualmente distinguible del resto de los controles de la
barra superior (filtros, exportar, importar, etc.), para que se
identifique como un elemento de estado ligado a la selección actual y
no como una acción o un control fijo de la pantalla.
