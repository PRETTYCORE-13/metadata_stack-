# Requirements — Crear endpoint a partir de una Consulta

## Contexto

Hoy una Consulta (Reporte, `schema_context_type = 3`) solo se consume
desde la propia plataforma (pantalla del reporte). Esta spec agrega una
forma de exponerla como una API HTTP propia, configurable sin escribir
código, para que un sistema externo pueda consultarla directamente.

**Hallazgos reales de la investigación previa (2026-09-10), que acotan
esta spec:**

- **Restricción técnica real**: las rutas de Phoenix se compilan — no
  se puede registrar una ruta nueva en caliente al publicar un
  endpoint. La solución (con precedente real en este mismo repo, la
  ruta comodín `live "/*ruta"` que ya resuelve cualquier catálogo en
  tiempo de ejecución) es UNA sola ruta comodín, compilada una única
  vez, bajo un prefijo fijo reservado — la ruta elegida por el admin
  siempre vive bajo ese prefijo, nunca en cualquier parte de la URL.
- **Ya existe una exposición implícita** (`GET /api/<nombre_consulta>`)
  para CUALQUIER Consulta, sin RBAC y sin publicar nada — un gap de
  seguridad preexistente. A pedido explícito, esta spec NO la toca; el
  endpoint que describe esta spec es una funcionalidad nueva y
  separada, con su propia ruta y su propia credencial.
- **No existe RBAC real en la capa de API hoy** (ni en la ruta de
  arriba ni en la API genérica de catálogos) — solo se verifica que
  haya sesión. Lo que describe esta spec es código nuevo, no
  "conectar" con un chequeo que ya exista.
- **No existe un concepto de credencial de servicio/API key** en la
  plataforma — el único mecanismo de token existente (app móvil) exige
  loguearse como un Usuario real. A pedido explícito, esta spec
  introduce una API key propia por endpoint publicado, sin atarla a
  ningún Usuario — el alcance de datos que aplica es el de la EMPRESA
  donde se publicó, igual que ya usa la Consulta, sin distinguir por
  usuario ni por sus permisos individuales.
- **Revisión técnica adicional (2026-09-10, a pedido del usuario)**:
  ronda de feedback que agregó paginación, timeout, esquema de
  autenticación explícito, protección de la credencial, validación de
  consistencia de parámetros y auditoría — todos incorporados abajo
  como requisitos numerados, no como notas aparte.

## Requisitos

### Configuración (dentro del editor de la Consulta)

**R1.** EL SISTEMA DEBE ofrecer, desde la configuración de una
Consulta, una opción para crear un endpoint API asociado a ella.

**R1.1** (agregado 2026-09-11, a pedido explícito — "lo quería
independiente" del modal "Nueva consulta"): EL SISTEMA DEBE ofrecer
también un atajo desde BC List, sobre cualquier catálogo normal, que
arme la Consulta interna necesaria SIN pasar por el formulario "Nueva
consulta" (sin pedir etiqueta/navegación/tablas relacionadas) y lleve
directo a la configuración del endpoint. La Consulta que arma este
atajo se crea oculta (`schema_visible: false` — no es un reporte para
navegar, es infraestructura del endpoint) pero sigue siendo una
Consulta común a todos los efectos: visible en BC List, editable,
eliminable — el atajo solo evita el paso manual del formulario, no
crea un tipo de objeto distinto.

**R2.** EL SISTEMA DEBE permitir configurar, para ese endpoint: un
nombre, un método HTTP (GET o POST), una ruta y una descripción.

**R3.** La ruta de un endpoint DEBE vivir siempre bajo un prefijo fijo
reservado para esta funcionalidad (ej. `/api/consultas/…`) — el
sistema no debe permitir publicar un endpoint fuera de ese prefijo.

**R4.** EL SISTEMA DEBE rechazar guardar dos endpoints activos con el
mismo método y la misma ruta.

**R5.** EL SISTEMA DEBE permitir elegir, únicamente entre los campos
de la Consulta que ya están marcados como Parámetro, cuáles de ellos
participan como parámetros de entrada del endpoint.

**R6.** Para cada parámetro de entrada elegido, EL SISTEMA DEBE
permitir marcarlo como obligatorio u opcional.

**R7.** Cada parámetro de entrada del endpoint DEBE conservar el tipo
de dato que ya tiene configurado en la Consulta (fecha, texto, entero,
decimal o referencia) — el endpoint no redefine tipos nuevos.

**R8.** EL SISTEMA DEBE permitir, como máximo, un endpoint configurado
por Consulta — no varios endpoints (distintos métodos/rutas) sobre la
misma Consulta.

**R8.1.** CUANDO un parámetro configurado en el endpoint deje de estar
marcado como Parámetro en la Consulta (o el campo se elimine), EL
SISTEMA DEBE impedir guardar la configuración del endpoint hasta que
se corrija — nunca debe quedar un endpoint guardado referenciando un
parámetro que ya no existe del lado de la Consulta.

### Ejecución y respuesta

**R9.** CUANDO se invoque un endpoint publicado con valores para sus
parámetros de entrada, EL SISTEMA DEBE ejecutar la Consulta subyacente
aplicando esos valores a los campos correspondientes — mismo criterio
que ya usa la pantalla de Parámetros del reporte.

**R9.1.** CUANDO el método sea GET, los parámetros DEBEN leerse del
query string; CUANDO el método sea POST, DEBEN leerse del cuerpo JSON
de la solicitud. La definición de parámetros del endpoint (nombre,
tipo, obligatorio) es la MISMA sin importar el método elegido.

**R10.** CUANDO falte un parámetro marcado como obligatorio, EL
SISTEMA DEBE rechazar la llamada con un error claro, sin ejecutar la
Consulta.

**R11.** La respuesta DEBE ser JSON, con los campos visibles de la
Consulta bajo una clave `"data"` (una lista de objetos, uno por
registro).

**R12.** EL SISTEMA NO DEBE permitir, a través de un endpoint
publicado, ninguna operación de creación, actualización ni
eliminación — únicamente lectura.

**R13.** EL SISTEMA NO DEBE aceptar un `empresa_id` (ni ningún dato
equivalente) enviado por quien llama al endpoint para elegir de qué
empresa trae datos — la empresa SIEMPRE sale de la configuración del
endpoint (fijada al guardarlo), nunca de la solicitud entrante.

### Paginación y límites de ejecución

**R14.** EL SISTEMA DEBE paginar la respuesta de todo endpoint
publicado — nunca debe devolver la totalidad de una Consulta sin
límite en una sola respuesta.

**R15.** Quien llama al endpoint DEBE poder indicar página y cantidad
de registros por página; si no los indica, EL SISTEMA DEBE aplicar
valores por default razonables.

**R16.** EL SISTEMA DEBE aplicar un tope máximo de registros por
página, que quien llama no puede superar aunque lo pida — un pedido
por encima del tope se recorta a ese máximo, nunca se rechaza de
plano.

**R17.** La respuesta DEBE incluir, junto a `"data"`, un bloque
`"meta"` con página actual, registros por página, total de registros
y total de páginas.

**R18.** EL SISTEMA DEBE limitar el tiempo máximo de ejecución de la
consulta subyacente disparada por un endpoint publicado; si se excede,
DEBE cancelar la ejecución y responder con un error, nunca dejar la
solicitud colgada indefinidamente.

### Seguridad

**R19.** EL SISTEMA DEBE permitir generar, en un endpoint, una
credencial (API key) — distinta de cualquier otra ya emitida, en ese
endpoint o en cualquier otro.

**R19.1** (agregado 2026-09-11, a pedido explícito — evolución "Nivel
3: Scopes"): EL SISTEMA DEBE permitir MÁS DE UNA credencial activa por
endpoint, cada una con nombre propio (ej. "ERP", "Tienda") — reemplaza
el modelo "una sola key por endpoint" de la primera versión de este
spec. Cada sistema externo que consuma el mismo endpoint recibe SU
PROPIA credencial, nunca comparten una.

**R20.** EL SISTEMA DEBE recibir la API key exclusivamente por el
encabezado HTTP `Authorization`, con el esquema `Bearer` — nunca por
query string ni por el cuerpo de la solicitud (una key en la URL
puede terminar en logs/historial/proxies intermedios).

**R21.** CUANDO se invoque un endpoint publicado, EL SISTEMA DEBE
exigir una credencial válida de ESE endpoint y rechazar la llamada
(sin ejecutar nada) si falta, no es válida, o fue revocada.

**R22.** Los datos que devuelve un endpoint publicado DEBEN acotarse a
la empresa donde se publicó (mismo alcance por empresa que ya aplica
la Consulta) — el endpoint no distingue por usuario ni aplica permisos
individuales, porque no hay un Usuario detrás de ninguna credencial.

**R23.** EL SISTEMA DEBE permitir regenerar cualquier credencial de un
endpoint en cualquier momento — esa credencial anterior deja de
funcionar de inmediato, SIN afectar a las demás credenciales del mismo
endpoint (R19.1).

**R23.1** (agregado 2026-09-11): EL SISTEMA DEBE permitir revocar una
credencial puntual (independiente de regenerarla) — queda inutilizable
para siempre, sin afectar a las demás credenciales del endpoint ni al
estado publicado/borrador del endpoint en sí.

**R24.** CUANDO un endpoint esté despublicado (borrador) o eliminado,
EL SISTEMA NO DEBE responder llamadas a su ruta, con o sin credencial
(ninguna credencial, sin importar cuál, funciona mientras el endpoint
no esté publicado).

**R25.** La API key completa de una credencial DEBE mostrarse
ÚNICAMENTE en el momento en que esa credencial se crea o se regenera —
en cualquier otro momento posterior, EL SISTEMA DEBE mostrarla
enmascarada (ej. solo los últimos caracteres visibles). El sistema NO
DEBE guardar la key de forma que pueda recuperarse en texto plano más
tarde, ni exponerla completa en respuestas de API, logs o
documentación.

### Alcance por campo de cada credencial (Nivel 3, agregado 2026-09-11)

**R42.** EL SISTEMA DEBE permitir elegir, al crear una credencial,
CUÁLES de los campos visibles del endpoint puede recibir esa
credencial en particular — un subconjunto propio, nunca más allá de lo
que el endpoint ya expone en general.

**R43.** CUANDO se invoque el endpoint con una credencial válida, cada
objeto de `"data"` DEBE incluir ÚNICAMENTE los campos permitidos de
ESA credencial — nunca los campos de otra credencial ni todos los que
tenga visibles el endpoint.

**R44.** EL SISTEMA NO DEBE permitir que quien llama elija qué campos
recibir (ej. un parámetro como `?fields=saldo,rfc`) — el subconjunto
de campos por credencial es fijo, se define del lado del admin al
crearla, y se aplica siempre en el servidor, nunca por lo que pida el
cliente.

**R45.** La pantalla de gestión de una o más credenciales de un
endpoint DEBE listar cada una con: nombre, estado (activa/revocada),
un resumen de su alcance (ej. "Solo lectura · 4 campos"), y acciones
para ver el detalle de permisos, regenerar, y revocar.

**R46.** Crear o revocar una credencial NO DEBE exigir que el endpoint
esté publicado — se pueden preparar credenciales de antemano sobre un
endpoint todavía en borrador, listas para cuando se publique.

### Flujo Guardar → Probar → Publicar

**R26.** EL SISTEMA DEBE permitir guardar la configuración de un
endpoint como borrador, sin exponerlo públicamente.

**R27.** EL SISTEMA DEBE permitir probar un endpoint YA guardado
(ejecutarlo contra datos reales, con parámetros de prueba elegidos por
el admin) y mostrar la respuesta real que devolvería, sin necesidad de
haberlo publicado antes.

**R28.** Probar un endpoint NO DEBE ser un paso obligatorio para poder
publicarlo — es una verificación disponible, no un bloqueo.

**R29.** EL SISTEMA DEBE permitir publicar un endpoint ya guardado,
momento en el que empieza a responder llamadas externas con una
credencial válida.

**R30.** EL SISTEMA DEBE permitir despublicar un endpoint publicado
(volver a borrador) en cualquier momento.

**R31.** CUANDO un endpoint esté publicado, EL SISTEMA DEBE mostrar el
método y la ruta completa (ej. "POST /api/consultas/ventas-producto"),
con una acción para copiarla, la lista de sus credenciales (R19.1,
R45) con acciones para regenerar/revocar cada una, y un acceso a su
documentación.

**R32.** La documentación de un endpoint publicado DEBE listar:
método, ruta, esquema de autenticación (R20), cada parámetro de
entrada (nombre, tipo, obligatorio u opcional), la forma de la
paginación (R14-R17), un ejemplo de LO QUE SE PUEDE ENVIAR (query
string completo para GET, o body JSON para POST, con los parámetros
configurados) y un ejemplo de respuesta (agregado 2026-09-11, a pedido
explícito: "que se vea el json que pueden enviar") — nunca debe incluir
una API key real, ni siquiera enmascarada.

### Auditoría

**R33.** EL SISTEMA DEBE registrar cada invocación a un endpoint
publicado: fecha/hora, endpoint, empresa, IP de origen, método,
resultado HTTP, duración y cantidad de registros devueltos.

**R34.** EL SISTEMA NO DEBE registrar la API key (ni completa ni
parcial) en ese log de auditoría.

### Grandes volúmenes de resultados (agregado 2026-09-11, a pedido explícito)

**R35.** EL SISTEMA NO DEBE fijar un tope al TOTAL de registros que una
Consulta expuesta puede procesar/devolver (una Consulta con más de
100,000 registros tiene que poder consumirse igual, completa, a lo
largo de varias llamadas) — cualquier límite de tamaño (R38) aplica
SOLO a cada respuesta/lote individual, nunca al resultado total.

**R36.** El endpoint NUNCA DEBE devolver el resultado completo de una
Consulta grande en una única respuesta HTTP, sin importar cuántos
registros tenga.

**R37.** Para llamadas síncronas, EL SISTEMA DEBE ofrecer paginación
por CURSOR (traer resultados en bloques a partir de una posición,
sin contar/cargar el conjunto completo en memoria de una sola vez) —
como una forma ADICIONAL de paginar, sin modificar ni reemplazar la
paginación por página numérica (`pagina`/`por_pagina`, R14-R17) ya
implementada — decisión explícita: "no modifiques lo que ya existe".

**R38.** El tamaño máximo de cada respuesta/lote en modo cursor DEBE
ser configurable, con un valor recomendado inicial de 5,000 registros
(tope independiente del que ya existe para `pagina`/`por_pagina`, R16).

**R39.** Para extracciones que necesiten TODO el resultado de una
Consulta grande (no un lote), EL SISTEMA DEBE permitir una ejecución
asíncrona mediante un Job: se dispara la ejecución en segundo plano y
se devuelve de inmediato una referencia para hacerle seguimiento.

**R40.** EL SISTEMA DEBE permitir consultar el estado de un Job
(pendiente/en curso/completado/fallido) y, una vez completado, obtener
sus resultados.

**R41.** El mecanismo completo (cursor + Jobs) DEBE evitar que una
Consulta de cientos de miles o millones de registros sature la
memoria del servidor, provoque un timeout, o bloquee otras
solicitudes mientras se procesa.

### Sección dedicada "Endpoints" (agregado 2026-09-14, a pedido explícito)

Pedido textual del usuario: *"es que no quiero que dependa de una
consulta, algo como sección endpoint donde pueda elegir el catálogo y
crear su endpoint"* -- reemplaza los dos caminos anteriores (atajo
"+ Endpoint" en BC List, R1.1; pestaña "Endpoint API" en
`ConsultaEditorLive`, ambos RETIRADOS).

**R47.** EL SISTEMA DEBE ofrecer una sección propia ("Endpoints", ítem
de navegación independiente) donde crear y gestionar un endpoint SIN
pasar por BC List ni por el editor de una Consulta -- la Consulta
interna que sostiene cada endpoint se crea de forma transparente, el
admin nunca la administra como tal.

**R48.** Al crear un endpoint nuevo, EL SISTEMA DEBE permitir elegir
un catálogo base y, opcionalmente, UNA tabla detalle relacionada, con
la unión entre ambas autodetectada (mismo mecanismo que ya usa BC List
para "Nueva consulta" con relaciones/maestro-detalle) -- si no se
detecta ninguna relación automática, EL SISTEMA NO DEBE crear nada y
DEBE pedir elegir otra tabla o ninguna. Decisión explícita confirmada
por el usuario: esto NO es el armador multi-tabla completo de "Nueva
consulta" (sin editor de unión manual, sin agregar una tercera tabla) —
si algún caso necesita eso, se arma como Consulta normal en BC List
primero.

**R49.** Al confirmar la creación (R48), EL SISTEMA DEBE dejar el
endpoint ya creado en estado "borrador" con valores por defecto
razonables (no debe quedar únicamente la Consulta interna sin ningún
`ConsultaEndpoint` asociado) -- así aparece de inmediato en el listado
de endpoints y siempre hay algo concreto para eliminar si el admin
abandona la configuración a mitad de camino.

**R50.** La sección de edición de un endpoint DEBE permitir marcar
qué campos son visibles y cuáles son Parámetro (con su configuración
de acotado/tipo de filtro/default) SIN salir de esa pantalla --
ninguna de las dos operaciones antes exclusivas de "Get Config" en
`ConsultaEditorLive` debe ser un paso obligatorio aparte.

**R51.** EL SISTEMA DEBE permitir eliminar un endpoint por completo
(la fila `ConsultaEndpoint`, sus credenciales, y la Consulta/Header
internos que lo sostenían) -- tanto desde el listado como desde la
propia pantalla de edición. Motivado por un caso real de este mismo
día: clicks repetidos del atajo viejo dejaron 3 Consultas ocultas
huérfanas, detectables solo con una consulta SQL directa a la base;
la sección nueva necesita una forma de limpiar eso desde la UI.

### Documentación por parámetro (agregado 2026-09-14, a pedido explícito)

El usuario mostró un mockup de referencia (documentación de un
"RQNotaDevolucionClienteEncabezado" externo, no de este sistema):
cada parámetro listado con su tipo, etiqueta, un texto de descripción
propio ("Identificador interno único de la transacción de venta que
se está devolviendo.") y si es obligatorio u opcional, más un ejemplo
de body en vivo al costado — pidió que la Documentación de ESTE
endpoint se vea así.

**R52.** Cada parámetro configurado de un endpoint DEBE poder tener su
propia descripción de texto libre (independiente de la etiqueta del
campo, que ya existe) — se carga al marcarlo activo en "Configuración
del endpoint" y se muestra en la sección Documentación.

**R53.** La sección Documentación DEBE listar cada parámetro con: su
clave, tipo, etiqueta, la descripción de R52, y si es obligatorio u
opcional — en un formato de lectura fácil (no una tabla densa
genérica), acompañado del ejemplo de solicitud/respuesta ya existente
(R32).

### Alta de registros vía POST (agregado 2026-09-14, a pedido explícito)

Pedido textual del usuario: *"pero necesito que el post agregue
registros"*. Hasta acá TODA la spec era de solo lectura (ver R (fuera
de alcance, abajo) -- ningún GET/POST tocaba la base, un POST era
únicamente "mandar los filtros por body". Esto agrega, de forma
EXPLÍCITA y opcional por endpoint, la capacidad de insertar.
Confirmado por el usuario vía pregunta directa: (1) aplica al MISMO
catálogo que ya expone el endpoint (no un catálogo/documento
distinto), y (2) el alta DEBE seguir las mismas reglas que un alta
manual desde la UI (motor de estados, folio/TRN si el catálogo es
transaccional), nunca un INSERT directo a la tabla.

**R54.** Un endpoint configurado como POST DEBE poder habilitar,
opcionalmente, que ese POST inserte un registro nuevo en su catálogo
base en vez de ejecutar una consulta -- los dos modos son EXCLUYENTES
por endpoint: si está habilitado, el body deja de interpretarse como
filtros de búsqueda.

**R55.** El admin DEBE poder elegir explícitamente qué campos reales
del catálogo puede mandar el caller externo (whitelist, mismo criterio
que `campos_permitidos` para lectura, R42-R44) -- cualquier campo que
el body mande pero no esté en esa lista se ignora, aunque el caller lo
incluya.

**R56.** El alta DEBE pasar por las MISMAS reglas que un alta manual
desde la UI -- motor de estados (nace en el estado inicial o sigue la
transición "alta" configurada), asignación de folio/TRN si el catálogo
es transaccional, y las validaciones de campos del catálogo (tipo,
obligatorio). Un catálogo sin ningún estado configurado DEBE rechazar
el alta con un error claro, nunca insertar en silencio.

**R57.** El registro nuevo DEBE quedar siempre asociado a la empresa
del endpoint (mismo criterio que la lectura, alcance fijo por
`{:empresa_fija, ...}`) -- si el body externo manda `empresa_id`, se
IGNORA; el valor real sale únicamente de la configuración del
endpoint, nunca de algo que pueda mandar quien llama.

**R58.** La respuesta de un alta exitosa DEBE ser `201 Created` con el
id del registro nuevo; un alta rechazada (validación, motor no
configurado) DEBE responder `422` con un mensaje de error legible, sin
insertar nada.

**Decisión de implementación documentada (no confirmada explícitamente
por el usuario, sujeta a revisión):** cualquier credencial ACTIVA del
endpoint puede usar el alta si está habilitada -- no existe hoy un
permiso "puede escribir" separado por credencial (la única distinción
por credencial sigue siendo `campos_permitidos` para LECTURA, R42-R44).
Si en el futuro hace falta que solo algunas credenciales de un mismo
endpoint puedan dar de alta, es una extensión pendiente, mismo
criterio que "Nivel 4" ya documentado como fuera de alcance.

### Renglones de detalle en el alta (agregado 2026-09-14, a pedido explícito)

Pedido textual del usuario, inmediatamente después de R54-R58: *"falta
las filas del detalle"* -- si `catalogo_base` es un catálogo MAESTRO
(caso real: `pty_lista_precios`/`pty_lista_precios_det`), el alta de
R54-R58 solo creaba el encabezado, nunca sus renglones.

**R59.** Si `catalogo_base` tiene uno o más catálogos detalle reales,
el admin DEBE poder habilitar, por cada catálogo detalle, qué campos
reales de ESE detalle puede mandar el caller externo (mismo criterio
de whitelist que R55, un nivel más abajo).

**R60.** El alta DEBE crear el encabezado y sus renglones en el MISMO
ciclo atómico (si algún renglón falla, el encabezado entero se
rechaza) -- reusando el mecanismo YA existente de
`CatalogoGenerico.crear/4` + `opciones[:renglones]`
(`MetadataApp.Renglones.crear_todos/3`), nunca un mecanismo propio.

**R61.** El body externo manda cada lista de renglones bajo la clave
del catálogo detalle real (mismo nombre que usa la whitelist de R59);
`encabezado_id` NUNCA lo manda el caller -- lo estampa el motor solo,
como ya hacía para cualquier alta manual maestro-detalle.

Verificado con datos reales (2026-09-14, contra el catálogo real del
usuario en dev, dentro de una transacción con rollback intencional):
un endpoint sobre `pty_lista_precios` con `renglones_alta` configurado
para `pty_lista_precios_det` creó el encabezado + 2 renglones reales
en el mismo alta, con motor de estados y TRN asignados igual que un
alta manual desde la Ficha 360°.

**Bug real encontrado y corregido durante esta verificación:** la
tabla "Obligatorio en el catálogo" (R55) leía la propiedad
`"obligatorio"` de `meta_schema_detail`, que NO EXISTE en un catálogo
real generado desde BC List -- ese usa `"opcional"` (invertido). Se
corrigió a `props["opcional"] == false`; sin la corrección, todo campo
real se mostraba siempre como "No obligatorio" sin importar su
contrato real.

### Campos "referencia" en el alta se identifican por descripción (agregado 2026-09-14, a pedido explícito -- revisado el mismo día)

Pedido textual del usuario, sobre el campo `pty_lista_precios_det_productos`
(tipo "referencia" hacia `pty_productos`): *"puedo tener el codigo del
producto en vez de la descripcion"*, aclarado después: *"es que es el
codigo que le da el sistema al producto no como tal el id"*.

**Iteración 1 (implementada y luego revertida en el mismo día):** ante
la duda de si se refería al TRN o al ULID, y la objeción propia del
usuario de que "descripción" puede repetirse (no es identificador
único), se recomendó y se implementó resolver por TRN (vía
`meta_schema_transaction_registry`). El usuario pidió explícitamente
revertirlo (*"regresalo como estaba por id interno"*, y acto seguido
*"regresalo como estaba por descripción"*) -- la versión final NO usa
TRN.

**R62.** Cualquier campo tipo "referencia" habilitado en `campos_alta`
o en `renglones_alta` DEBE identificarse, del lado del caller externo,
por su campo de descripción/acompañamiento real (el mismo que ya usa
`CatalogoGenerico.opciones_referencia/3` para mostrar la etiqueta de
un selector de referencia -- `props["campos_acompanamiento"]`, ej.
`pty_productos_descripcion` para `pty_lista_precios_det_productos`),
NUNCA por su id interno autoincremental ni por TRN.

**R63.** Dado que ese campo de descripción NO tiene garantía de ser
único (objeción propia del usuario), EL SISTEMA DEBE exigir
EXACTAMENTE una coincidencia antes de insertar -- si no hay ninguna
coincidencia, o si hay más de una, DEBE rechazar el alta completa con
un error claro (`422`) que distinga ambos casos, sin insertar nada ni
elegir una coincidencia al azar.

**R64.** La UI y la documentación del endpoint DEBEN dejar explícito,
para cada campo tipo "referencia", que se espera la descripción (no un
id) y que debe ser única -- tanto en la tabla de configuración de
campos como en el "Ejemplo de solicitud".

Verificado con datos reales (2026-09-14, `pty_lista_precios_det_productos`
→ `pty_productos` en dev, transacción con rollback intencional, 3
casos): descripción única → resuelve al id correcto y crea el
renglón; descripción que coincide con DOS productos → rechaza con
`{:referencia_ambigua, "pty_lista_precios_det_productos", "<descripcion>"}`;
descripción que no coincide con ninguno → rechaza con
`{:referencia_no_encontrada, "pty_lista_precios_det_productos", "<descripcion>"}`.
Ninguno de los dos casos de error insertó nada.

## Fuera de alcance (explícito, a pedido)

- La ruta implícita ya existente (`GET /api/<nombre_consulta>`) — se
  documenta como hallazgo, no se modifica en esta spec.
- Cualquier chequeo de permisos por Usuario para el endpoint publicado
  — el alcance es únicamente por empresa (R22).
- Más de un endpoint por Consulta (R8).
- Alcance por sucursal/almacén/unidad de venta/"propio" en un endpoint
  publicado — si la Consulta lo necesita, el endpoint igual se publica
  acotado solo por empresa (decisión explícita, ver design.md).
- **Rate limiting real (a pedido explícito):** el CONTRATO queda
  definido (ver Fuera de alcance de implementación) pero NO se
  implementa en esta spec — límite de solicitudes por API key,
  respuesta 429 al excederlo, y cualquier mecanismo de conteo/ventana
  quedan para una spec o iteración aparte.
- **"Nivel 4" de la evolución de seguridad (agregado 2026-09-11, a
  pedido explícito del propio usuario -- "futuro", en sus palabras):**
  filtros permitidos y rate limit propios POR CREDENCIAL (más allá del
  alcance por campo de R42-R44, y del alcance por empresa de R22, que
  ya siguen aplicando a TODAS las credenciales de un endpoint por
  igual) quedan fuera de esta spec.
- **Editor de unión manual / más de una tabla detalle en la sección
  "Endpoints" (agregado 2026-09-14, a pedido explícito -- ver R48):**
  el picker de `:nuevo` solo ofrece catálogo base + UNA tabla detalle
  con unión autodetectada. Un caso que necesite una unión manual o más
  de dos tablas sigue el camino de "Nueva consulta" en BC List, no
  esta sección.

### Alta: rechazar en vez de insertar vacío si el body no coincide con nada (agregado 2026-09-17, a pedido explícito)

Caso real: un caller externo integrando el endpoint de "historico"
mandó el body con `Content-Type: text/plain` (no `application/json`)
-- Phoenix nunca llegó a parsear nada, el endpoint igual respondía
`201` (todos los campos son opcionales) y creaba una fila con TODOS
los campos de negocio en NULL, sin ningún aviso. Mismo síntoma posible
con nombres de campo viejos/mal escritos que no matchean la whitelist.

**R65.** Si `endpoint.campos_alta` tiene algo configurado pero NINGUNA
clave del body coincide con esa whitelist, EL SISTEMA DEBE rechazar el
alta completa con `422` y un mensaje que incluya los nombres de campo
que sí acepta (para que el caller pueda comparar contra lo que mandó)
-- nunca debe insertar una fila con todos los campos de negocio vacíos
sin avisar.

Verificado con datos reales (dev, `endpoint_historico_127138`): un
body real enviado con `Content-Type: text/plain` desde un cliente
C#/RestClient generado por Postman fue la causa real de este hallazgo.

### Permiso propio para la sección "Endpoints" (agregado 2026-09-17, a pedido explícito)

Caso real: el usuario abrió la pestaña "Sysadmin" de un usuario
(`UsuariosEmpresaLive`) esperando ver un switch "Endpoints" al lado de
"Business Process Builder" y no estaba -- la sección "Endpoints"
(R47-R51) nació dependiendo del mismo recurso `sysadmin_bc` que el
resto de Business Process Builder, sin switch propio.

**R66.** EL SISTEMA DEBE ofrecer "Endpoints" como una capacidad de
Sysadmin propia, independiente de "Business Process Builder", con su
propio switch en la pestaña "Sysadmin" de `UsuariosEmpresaLive` -- un
usuario puede tener acceso a una sin la otra.

Cualquier rol que ya tuviera acceso a Endpoints por tener
`sysadmin_bc`/`editar` concedido (vía el switch viejo de "Business
Process Builder") conserva ese acceso automáticamente al migrar --
nadie pierde acceso que ya tenía (ver migración
`20260917180000_seed_permiso_capacidad_sysadmin_endpoints.exs`).

## Publicar Endpoints entre ambientes (agregado 2026-09-17, a pedido explícito)

Hallazgo real: un endpoint creado y publicado en local respondía 404
("Endpoint no encontrado") al invocarlo contra `unstable` -- la
configuración nunca llegó a esa base, y la pantalla de administración
(`/sysadmin/endpoints`) tampoco existe ahí (queda detrás del mismo
flag que apaga todo Business Process Builder en cualquier release
compilado). A diferencia de un catálogo, que sí tiene un camino
explícito para viajar de local a cualquier ambiente
(`mix motor.publicar`/`motor.despublicar`), un Endpoint no tenía
ninguno -- hueco no contemplado en el diseño original de esta spec.

Modelo acordado con el usuario (separa tres cosas que hoy conviven
implícitas en un solo mecanismo):

- **Endpoint** -- su ciclo borrador ⇄ publicado ya existe (R24/R30),
  sin cambios acá.
- **Promoción** -- lleva el Endpoint (config + la Consulta de la que
  depende) entre ambientes.
- **Credenciales/Tokens** -- se crean directo en cada ambiente, nunca
  viajan con la promoción; activarlas/rotarlas/revocarlas es
  independiente del ciclo del Endpoint. El alcance de acceso sigue
  siendo por pertenencia (1 credencial = 1 Endpoint, ya implementado
  en `ConsultaEndpointCredencial`, R19.1/R42-R46) -- confirmado con el
  usuario, sin cambio de modelo ahí (se evaluó y se descartó pasar a
  que un mismo token autorice varios Endpoints).

**R67.** EL SISTEMA DEBE ofrecer un mecanismo para llevar la
configuración de un Endpoint (nombre, método, ruta, parámetros, campos
visibles/de alta) y la Consulta de la que depende (si todavía no
existe en el destino) desde donde se construyó hacia cualquier
ambiente donde deba responder, sin requerir que la pantalla de
administración de Endpoints exista en ese ambiente.

**R68.** CUANDO se lleve un Endpoint a un ambiente donde ya existe uno
con el mismo nombre, EL SISTEMA DEBE reemplazar su configuración
completa (incluyendo su estado borrador/publicado), nunca duplicarla.

**R69.** EL SISTEMA NO DEBE incluir ninguna credencial existente como
parte de lo que se traslada entre ambientes -- cada ambiente exige que
sus credenciales se generen directamente ahí, nunca heredadas ni
copiadas de otro.

**R70.** Activar, rotar o revocar una credencial de un Endpoint DEBE
ser independiente del ciclo borrador/publicado de ese Endpoint y de
cualquier evento de promoción -- ninguna de las dos operaciones
requiere ni provoca la otra.

**R71.** CUANDO se elimine un Endpoint en el origen, EL SISTEMA DEBE
ofrecer una forma explícita de reflejar esa baja en cualquier ambiente
donde ya se había llevado -- mismo criterio que `mix motor.despublicar`
ya exige para un catálogo borrado; esto deja huérfanas (y por lo tanto
inválidas) las credenciales que dependían de ese Endpoint en ese
ambiente.

## La pantalla de administración de Endpoints en cualquier ambiente (agregado 2026-09-17, a pedido explícito)

Hallazgo real, probando R67-R71 de punta a punta contra `unstable`: el
catálogo y su Endpoint llegaron bien (vía `mix motor.publicar`), pero
`/sysadmin/endpoints` respondía "Catálogo no encontrado" ahí -- esa
pantalla está detrás del mismo flag que apaga TODO Business Process
Builder en un release compilado (`bpb_habilitado`), así que R69/R70
(generar/rotar una credencial "directo en cada ambiente, vía
`/sysadmin/endpoints`") describían un lugar que en la práctica no
existe en `unstable`/`testing`/`stable`/un cliente. Contradicción
encontrada dentro del propio spec, corregida acá antes de seguir.

**R72.** EL SISTEMA DEBE permitir **ver** la configuración de un
Endpoint, **generar/rotar/revocar sus credenciales**, y **consultar su
documentación** (qué mandar, qué responde) en CUALQUIER ambiente,
incluido un release compilado donde Business Process Builder esté
apagado -- ninguna de estas operaciones depende de generar un módulo
Ecto ni de migrar una tabla física.

*(Revisado 2026-09-18 -- ver R76: la redacción original decía "crear,
editar, publicar/despublicar" en cualquier ambiente; eso quedó
corregido después de un hallazgo real, un Endpoint duplicado creado
sin querer directo en `unstable` una vez que esta regla dejó esa
pantalla abierta ahí. Autoría de la definición ahora es R76, dev-only.)*

## Publicar/despublicar un Endpoint sin terminal (agregado 2026-09-17, a pedido explícito)

Verificado R67-R72 de punta a punta por terminal (`mix motor.publicar`/
`mix endpoint.despublicar`) -- a pedido explícito del usuario
("QUIERO NO TENER QUE METER COMANDOS EN LA TERMINAL"), se agrega el
mismo mecanismo como acción directa en la pantalla de Endpoints.

**R73.** EL SISTEMA DEBE permitir publicar un Endpoint a un ambiente
elegido (y quitarlo de ahí) desde la propia pantalla de Endpoints, sin
requerir ningún comando de terminal -- mismo resultado que `mix
motor.publicar`/`mix endpoint.despublicar`.

**R74.** Quitar un Endpoint de UN ambiente puntual desde esta pantalla
NO DEBE requerir borrarlo antes en local -- a diferencia de `mix
endpoint.despublicar` (pensado para cuando el Endpoint ya no existe en
ningún lado), acá el Endpoint sigue vivo local y en cualquier otro
ambiente donde ya se publicó; solo deja de responder en el ambiente
elegido.

**R75.** Esta acción DEBE estar disponible únicamente donde ya hoy
existe la herramienta de publicar (mismo ambiente que tiene Business
Process Builder habilitado) -- nunca en un release compilado, que no
tiene `gh`/`tar` ni sentido como origen de una publicación.

## Autoría de un Endpoint, solo en local (agregado 2026-09-18, a pedido explícito)

Hallazgo real (2026-09-17): con R72 permitiendo crear/editar un
Endpoint en CUALQUIER ambiente, se creó sin querer un endpoint
duplicado directo en `unstable` (`endpoint_pty_h_historico_499`) al
entrar a "Nuevo Endpoint" ahí en vez de usar el ya publicado desde
local -- mismo tipo de deriva que el resto de la plataforma ya evita
para catálogos (nunca se crean en producción, solo se publican desde
local). A pedido explícito, se alinea Endpoints con ese mismo criterio.

**R76.** Crear un Endpoint nuevo y editar su definición (campos, ruta,
método, parámetros, configuración de alta) DEBE estar disponible
ÚNICAMENTE donde Business Process Builder está habilitado -- igual que
un catálogo real, la definición se autoría en local y viaja por
publicación (R73), nunca se edita directo en un ambiente desplegado.
Ver/generar/rotar/revocar credenciales y consultar la documentación
(R72, sin cambios) siguen disponibles en cualquier ambiente.
