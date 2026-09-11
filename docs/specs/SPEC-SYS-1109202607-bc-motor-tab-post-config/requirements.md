# SPEC-SYS-1109202607 — BC Motor: Tab Post Config

**Documento:** Requirements · **Fase:** ✅ aprobada (2026-09-11) — documentación retroactiva + 1 fix real (R6a, ver `tasks.md`).

**Alcance de esta spec**: documentar (retroactivo, ya implementado)
el tab **"Post Config"** de `BcMotorLive` — séptima y última spec de
este primer barrido del módulo BC Motor. Este tab embebe
`PlantillaConstructorLive` (mismo LiveView que también existe como
ruta propia `/sysadmin/bc-list/:nombre/plantilla`), el "Constructor":
un editor visual de grid que arma la definición que `FichaLive` usa
para renderizar el tab "Datos" de la Ficha 360° de un catálogo, en
vez de la lista plana de campos por default.

**Alcance deliberadamente acotado**: esta spec documenta el CICLO DE
VIDA de una plantilla (crear, guardar, publicar, disponibilidad,
conflicto de edición concurrente) y su integración como tab de BC
Motor — NO el editor de grid en sí (paleta de componentes, arrastrar
y soltar, combinar/separar celdas, campo calculado, condiciones). Esa
parte es lo bastante grande y autocontenida (mecanismo "Grid 2D"
documentado en el moduledoc de `MetaPlantillas`) como para merecer su
propia spec si hace falta más adelante — no es lo que se pidió hoy.

## 1. Visibilidad e integración

R1. EL SISTEMA DEBE mostrar el tab "Post Config" para CUALQUIER
catálogo, incluidos los catálogos detalle — cada catálogo (maestro o
detalle) tiene su propia Ficha 360°/plantilla, independiente de la de
cualquier otro.

R2. EL SISTEMA DEBE embeber el Constructor completo dentro del tab,
sin salto de página — misma pantalla que la ruta propia
`/sysadmin/bc-list/:nombre/plantilla`, que sigue existiendo aparte
por si algo enlaza directo ahí.

## 2. Dos propósitos de plantilla

R3. EL SISTEMA DEBE distinguir dos propósitos de plantilla,
agrupados por separado en el selector: **"Vistas"** (lo que ve
cualquier usuario en el tab "Datos" de la Ficha 360°) e
**"Impresión"** (lo que se genera al usar el botón Imprimir/guardar
como PDF) — un catálogo puede tener cualquier cantidad de plantillas
de cada propósito, pero cada una pertenece a uno solo, nunca a los
dos.

R4. EL SISTEMA DEBE ofrecer botones de alta separados por propósito
("+ Nuevo PostView" para Vistas, "+ Nueva plantilla de impresión"
para Impresión) — nunca un único botón genérico que obligue a elegir
el propósito después.

## 3. Estado: borrador y publicada

R5. CADA plantilla DEBE tener un estado — "○ Borrador" o "●
Publicada" — visible junto al selector.

R6. A LO SUMO una plantilla por PROPÓSITO (Vista o Impresión) puede
estar "Publicada" a la vez, por catálogo — publicar una nueva DEBE
degradar automáticamente a "Borrador" cualquier otra del mismo
propósito que estuviera publicada antes, nunca dejar dos plantillas
"Publicada" del mismo propósito conviviendo.

## 4. Disponible como vista (multi-vista)

R7. EL SISTEMA DEBE ofrecer, independiente de publicar/despublicar,
un interruptor "Disponible como vista" por plantilla de propósito
"Vista" — activado, esa plantilla aparece como opción elegible en el
selector "Vista" que ve el usuario final al abrir un registro
(alternativa a la plantilla publicada por default), sin necesidad de
que esté publicada.

## 5. Guardar, publicar y conflicto de edición concurrente

R8. "Guardar" DEBE persistir el diseño actual sin cambiar su estado
(un borrador guardado sigue siendo borrador); "Publicar" DEBE
guardar Y además promoverla a "Publicada" (degradando cualquier otra
del mismo propósito, R6) en una sola acción — nunca dos pasos
separados obligatorios para publicar un cambio.

R9. CUANDO alguien más guardó cambios sobre la MISMA plantilla
mientras el usuario actual la tenía abierta (detectado comparando el
identificador de la última escritura contra el que tenía cargado al
empezar a editar), EL SISTEMA DEBE rechazar el "Guardar"/"Publicar"
con un aviso explícito de conflicto y un botón "Recargar" — nunca
sobrescribir en silencio el trabajo de otra persona ni perder el
propio sin avisar.

R10. "Recargar" (R9) DEBE descartar el borrador local en memoria y
traer la versión real más reciente desde la base — tanto la
plantilla actual como la lista completa (por si otra plantilla del
mismo catálogo también cambió de estado mientras tanto).

## 6. Utilidades

R11. EL SISTEMA DEBE ofrecer "Vista previa" — abre, en una pestaña
nueva, la Ficha 360° de un registro (nuevo en blanco, no hace falta
tener datos cargados) forzando el diseño actual, SIN publicarlo —
guarda el borrador actual automáticamente antes de abrir la pestaña
(la vista previa lee la plantilla desde la base por id, no puede
mostrar cambios que solo existen en memoria del navegador).

R12. EL SISTEMA DEBE ofrecer "↻ Regenerar automática" — reconstruye
la plantilla automática (todos los campos visibles, una columna × N
filas, formato de siempre) con el formato/campos actuales del
catálogo, PARA catálogos generados antes de que este editor de grid
existiera — nunca cambia cuál plantilla está publicada, es
independiente de eso.

R6a. **Corregido 2026-09-11** (hallazgo real, no un requisito
nuevo): la paleta de "Campo del catálogo" del Constructor ofrecía 8
campos de control (ID/Estado/TRN/Empresa/Sucursal/Almacén/Unidad de
venta/Creado por) pero le faltaba **Folio**, aunque el render de ese
campo ya estaba soportado en `FichaLive` desde la feature de folio
(`SPEC-SYS-0109202601` R9) — un catálogo con folio no podía colocar
un nodo "Folio" al armar una plantilla custom, solo lo veía en la
fila fija de la plantilla automática. Agregado a la paleta,
consistente con el resto de la app.

## 7. Fuera de alcance de esta spec

- El editor de grid en sí (paleta completa, arrastrar/soltar,
  combinar/separar celdas, deshacer/rehacer, zoom, todos los tipos
  de nodo — Sección/Panel/Pestañas/Tabla relacionada/Campo
  calculado/Botón/Resumen/Timeline/etc.) — candidato a spec propia.
- El modelo de datos "Grid 2D" de `MetaPlantillas` en profundidad.
- Cómo `FichaLive` consume la plantilla publicada en tiempo real
  (`plantilla_a_mostrar/2`, `nodo_plantilla_render/1`).
- El módulo `ImportacionConstructorLive` (tab "Importación", mismo
  patrón de embed pero un editor distinto, fuera del alcance de hoy).
