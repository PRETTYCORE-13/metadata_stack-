# SPEC-SYS-1109202606 — BC Motor: Tab Get Config

**Documento:** Requirements · **Fase:** ✅ aprobada (2026-09-11) — documentación retroactiva + 1 fix real (R14, código muerto eliminado, ver `tasks.md` Grupo D).

**Alcance de esta spec**: documentar (retroactivo, ya implementado)
el tab **"Get Config"** de `BcMotorLive` — todo lo que controla cómo
se ve la tabla de un catálogo cuando el usuario final la abre en
`CatalogoLive` (qué columnas, en qué orden, con qué orden de filas
por default, y si carga todo de entrada o espera un filtro). Sexta
spec del módulo BC Motor.

## 1. Visibilidad del tab

R1. EL SISTEMA DEBE mostrar el tab "Get Config" para CUALQUIER
catálogo, incluidos los catálogos detalle — a diferencia de Estados/
Transiciones/Diagrama/Contrato/Permisos, un catálogo detalle SÍ tiene
sus propios campos y su propia vista de tabla (la de sus renglones),
independiente de la de su maestro.

## 2. Columnas del GET — grilla unificada

R2. EL SISTEMA DEBE mostrar, en una sola tabla arrastrable, TODAS las
columnas posibles de este catálogo mezcladas: los campos de negocio
del catálogo Y los campos de control del sistema (ID, Estado, TRN,
Folio, Empresa, Sucursal, Almacén, Unidad de venta, Creado por) — con
una etiqueta de tipo ("Control" o "Negocio") por fila para
distinguirlos, nunca dos tablas separadas.

R3. LOS campos de control "Empresa", "Sucursal", "Almacén" y "Unidad
de venta" DEBEN aparecer en esta grilla únicamente cuando el catálogo
tiene Alcance de Datos activado (ver
`SPEC-SYS-1109202605-bc-motor-tab-permisos-alcance` §4) — esas
columnas no existen físicamente en la tabla si Alcance de Datos nunca
se activó.

R4. CADA fila DEBE tener un checkbox de visibilidad independiente
("¿aparece esta columna en la tabla del usuario final?") — con
atajos "Seleccionar todos"/"Deseleccionar todos" que marcan/desmarcan
todos los checkboxes visibles antes de enviar el formulario, sin
round-trip al servidor por cada uno.

R5. EL SISTEMA DEBE permitir reordenar estas filas por
arrastre — el orden combinado (control + negocio mezclados) se
guarda una sola vez por catálogo, independiente del "orden" propio
de cada campo de negocio que se usa en el tab Configuración/Ficha/
contrato de API (dos conceptos de orden separados, sin pisarse).

R6. CUANDO un campo del catálogo es elegible como Parámetro estándar
(según su tipo) o tiene Totales configurables, EL SISTEMA DEBE
ofrecer esos controles en la misma fila de la grilla — comportamiento
documentado en `SPEC-SYS-0209202601-parametros-catalogo`, no repetido
acá.

R7. EL SISTEMA DEBE persistir TODOS los cambios de visibilidad (de
negocio y de control) en un solo submit — nunca un guardado parcial
donde algunos campos queden con la visibilidad vieja porque el
usuario solo tocó una parte de la grilla.

## 3. Orden de resultados

R8. EL SISTEMA DEBE ofrecer, en una sección aparte ("Orden de
resultados"), una lista ordenada de campos que define el orden por
default de las filas — el primero de la lista manda, los siguientes
desempatan, cada uno con su propia dirección (ascendente/descendente)
alternable con un clic.

R9. CADA entrada de esta lista DEBE poder moverse (subir/bajar
prioridad) o quitarse individualmente — sin tener que rearmar la
lista completa desde cero para un solo cambio.

R10. EL usuario final DEBE poder seguir cambiando el orden desde la
propia tabla en cualquier momento — este orden es solo el punto de
partida por default, no una restricción permanente.

## 4. Campos por default

R11. EL SISTEMA DEBE ofrecer un interruptor "Campos por default" —
activado, la tabla trae TODOS los registros y columnas apenas se
abre, sin esperar que el usuario final aplique un filtro o búsqueda
primero.

## 5. Filtros por default

R12. EL SISTEMA DEBE ofrecer, independiente de "Campos por default"
(R11 — cualquiera de las dos funciona sola o ambas juntas), un
interruptor de modo para acotar la tabla por fecha de alta apenas se
abre, con 6 opciones reales: Sin acotar, Fecha actual, Mes actual
completo, Mes actual a la fecha, Año actual completo, o Fórmula
(texto libre parseado por `FormulaFecha`) — los primeros 5 son
dinámicos, se recalculan solos contra la fecha de hoy en cada
consulta, sin depender de ningún valor guardado.

R13. CUANDO se cambia de modo, EL SISTEMA DEBE limpiar cualquier
valor fijo guardado de un modo anterior.

R14. **Corregido 2026-09-11** (hallazgo real, no un requisito nuevo):
el código tenía una rama completa (selectores de fecha "Desde"/
"Hasta") para un séptimo modo, `"rango"`, que ningún botón real de
la UI podía activar — no estaba entre las 6 opciones de R12 — y que
`FiltrosDefault.rango_fecha/3` tampoco implementaba (caía a un
catch-all que no acotaba nada). Código muerto de una versión
anterior del vocabulario de modos. A pedido explícito del usuario
(entre restaurarlo o terminar de borrarlo), se eliminó la rama de UI
y el `handle_event` que era su único emisor — ver `design.md` §6 y
`tasks.md` Grupo D.

## 6. Fuera de alcance de esta spec

- El detalle de Parámetros estándar y Totales por columna
  (`SPEC-SYS-0209202601-parametros-catalogo`).
- Cómo `CatalogoLive` consume esta configuración en tiempo real —
  acá solo se documenta cómo se CONFIGURA, no cómo se aplica.
