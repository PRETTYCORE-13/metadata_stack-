# SPEC-SYS-1109202603 — BC Motor: Tab Contrato

**Documento:** Requirements · **Fase:** ✅ aprobada (2026-09-11) — documentación retroactiva, sin cambios de código.

**Alcance de esta spec**: documentar (retroactivo, ya implementado,
sin tocar código) el tab **"Contrato"** de `BcMotorLive`
(`/sysadmin/bc-list/:tabla/motor`) — documentación de API generada
automáticamente a partir de lo que ya se configuró en los tabs
Configuración (`SPEC-SYS-1109202601`) y Reglas: una tarjeta por
endpoint real (método + URL + descripción + body de ejemplo +
respuesta de ejemplo), siempre en sincronía porque se arma en vivo
desde los mismos datos, nunca a mano. Tercera spec del módulo BC
Motor (mismo prefijo "BC Motor" en el título, ver
`SPEC-SYS-1109202601-bc-motor-tab-configuracion` §0).

## 1. Visibilidad del tab

R1. EL SISTEMA DEBE mostrar el tab "Contrato" únicamente para
catálogos que NO son detalle — un catálogo detalle no tiene contrato
de API independiente, sus endpoints se documentan DENTRO del
contrato de su maestro (ver R5).

## 2. Endpoints de lectura

R2. EL SISTEMA DEBE documentar siempre `GET /api/:tabla` (listado
paginado) y `GET /api/:tabla/:id` (un registro), con un ejemplo de
respuesta armado con datos ficticios coherentes con los campos reales
del catálogo — nunca un placeholder genérico tipo `"string"` para
todo.

R3. CUANDO el catálogo tiene datos en `meta_campos_detalle` (o sea,
tiene al menos un catálogo detalle), EL SISTEMA DEBE agregar esa
llave a los ejemplos de respuesta de lectura — omitida por completo
(ni siquiera como `{}`) para cualquier catálogo sin detalles, para no
ensuciar el contrato de la enorme mayoría de catálogos que no lo
necesitan.

## 3. Endpoints de renglones (catálogo maestro-detalle)

R4. POR CADA catálogo detalle del maestro, EL SISTEMA DEBE
documentar `GET /api/:catalogo_detalle?encabezado_id=:id` (todos los
renglones de un registro puntual), aclarando en la descripción que el
filtro por query string acepta cualquier campo real del catálogo, no
solo `encabezado_id`.

R5. EL SISTEMA DEBE aclarar, en el mismo tab Contrato del maestro,
que un catálogo detalle NO tiene su propia pestaña Contrato — toda su
documentación de API (forma de sus filas, filtro por query string)
vive acá, no en un tab propio inexistente.

## 4. Endpoints de alta

R6. EL SISTEMA DEBE documentar `POST /api/:tabla` con un body de
ejemplo — si el catálogo tiene detalles, el body incluye una llave
`"renglones"` con DOS items de ejemplo por cada catálogo detalle
(nunca uno solo, para dejar visualmente claro que es una lista sin
límite fijo, no un campo de "un renglón"), sin `renglon_id` (son
altas nuevas, el motor lo asigna). Sin detalles, el body es
exactamente el de siempre, sin la llave.

R7. EL SISTEMA DEBE documentar también la variante batch
(`POST /api/:tabla` con body = lista, crea varios registros en un
solo request) — su ejemplo de body es deliberadamente distinto del de
R6: sin `"renglones"` por item, para no mezclar dos conceptos
("cuántos registros" vs. "cuántos renglones tiene UN registro") en el
mismo ejemplo y generar confusión.

R8. CUANDO el catálogo tiene una (o más) transición de alta
(`estado_origen_id` nulo), EL SISTEMA DEBE mostrar un aviso
explicando que esa transición corre AUTOMÁTICAMENTE dentro del
`POST /api/:tabla` de R6 — nunca como endpoint propio
`POST /:id/transiciones/<accion_de_alta>`, porque ese endpoint
siempre fallaría (un registro recién creado nunca tiene
`estado_id: nil`, precondición que ese camino exige).

## 5. Endpoints de transición

R9. CUANDO el catálogo tiene al menos una transición (además de la
de alta), EL SISTEMA DEBE documentar `GET /api/:tabla/:id/transiciones`
(las disponibles desde el estado actual de un registro puntual, con
sus precondiciones ya evaluadas) y una tarjeta `POST
/api/:tabla/:id/transiciones/:accion` por cada transición normal
configurada.

R10. EL body de ejemplo de cada transición (R9) DEBE separar los
campos editables por dueño real (header vs. cada catálogo detalle
que participe) — nunca por prefijo de nombre de campo — agrupando
los del header sueltos en el body y los de cada detalle dentro de
`"renglones": {"<catalogo>": [...]}`, coherente con el payload real
que el motor acepta.

R11. CUANDO una transición no tiene ningún campo editable propio del
header pero el catálogo SÍ tiene detalles, EL SISTEMA DEBE aclarar en
la descripción que igual puede mover renglones (aunque no edite
ningún campo de ellos) — un renglón de ejemplo con solo
`"renglon_id"` se documenta siempre, sea cual sea la transición.

R12. LA respuesta de ejemplo de una transición DEBE mostrar el
registro resultante con `estado_id`/`estado_nombre` ya en el estado
destino y los campos editables del header con su valor de ejemplo
aplicado — una fotografía de "cómo queda" el registro después de esa
transición, no del estado anterior.

## 6. Generación de valores de ejemplo

R13. EL SISTEMA DEBE generar un valor de ejemplo por campo según su
tipo (string → texto plano, integer → un número, decimal → un
decimal, boolean → true, date/hora → una fecha/hora fija de ejemplo,
enum → el primer valor configurado, referencia → un id numérico) —
nunca el mismo placeholder genérico sin importar el tipo real.

R14. LOS ejemplos de "data" de un registro (lectura o respuesta de
alta/transición) DEBEN incluir `id` (y `estado_id`/`estado_nombre`
cuando el catálogo adoptó el motor) — nunca campos de sistema
editables por PATCH directo (`estado_id` está deliberadamente fuera
de la whitelist de campos de negocio; el único camino para cambiarlo
documentado es una transición).

R15. EN cualquier JSON de ejemplo que tenga la llave `"id"`, EL
SISTEMA DEBE mostrarla PRIMERO, antes que cualquier otro campo —
tanto en el nivel raíz como en cualquier mapa anidado (ej. cada item
de una lista) — para que el ejemplo se lea con la convención habitual
de una API REST, sin depender del orden interno (no determinístico)
en que Elixir itera un mapa.

## 7. Presentación

R16. CADA endpoint documentado DEBE mostrarse como una tarjeta
independiente con: método HTTP (con color propio por método — GET
azul, POST verde, PATCH ámbar, DELETE rojo), URL en fuente
monoespaciada, descripción en texto plano, bloque "Body" (si aplica)
y bloque "Respuesta `<status>`" — ambos como JSON con sangría,
desplazable horizontalmente si es más ancho que la tarjeta.

R17. CUANDO el catálogo todavía no tiene ninguna transición
configurada, EL SISTEMA DEBE mostrar un texto claro ("Este catálogo
todavía no tiene transiciones definidas.") en vez de una sección de
transiciones vacía sin explicación.

## 8. Fuera de alcance de esta spec

- Edición de estados/transiciones/campos (documentado en
  `SPEC-SYS-1109202601-bc-motor-tab-configuracion`).
- El mecanismo real de autenticación/autorización de estos endpoints
  (documentado, si hace falta, en una spec propia de la API — acá
  solo se documenta LA FORMA del contrato, no cómo se protege).
- El tab "Permisos" (quién puede ejecutar cada transición) — mencionado
  acá solo porque comparte catálogo/transiciones, spec propia si hace
  falta documentarlo.
