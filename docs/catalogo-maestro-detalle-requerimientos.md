# Catálogo Maestro-Detalle — Requerimiento funcional y técnico

Estado: **completo, las 5 fases implementadas y verificadas de punta a punta** (ver §8), más 3 huecos post-Fase 5 encontrados en pruebas manuales y ya corregidos: (1) `MetaEstadosAdmin.completitud/1` bloqueaba para siempre el botón "Guardar BC" de un catálogo detalle (exigía estados que nunca le aplican); (2) `BcMotorLive` no sabía que un catálogo era detalle — mostraba Estados/Diagrama/Contrato como si fuera independiente; (3) alta atómica de renglones al crear el maestro (ver R6). Documento de referencia — no reemplaza al motor existente, lo extiende.

## 1. Contexto y objetivo

El motor (BPB) hoy genera catálogos planos: un header (`meta_schema_header`) + sus campos (`meta_schema_detail`) + un autómata opcional (estados/transiciones/reglas). Existen casos de negocio reales (ej. un pedido) donde un registro "encabezado" necesita N registros "hijos" con su propio conjunto de campos, que viven y mueren junto con el ciclo de vida del encabezado — el clásico patrón maestro-detalle (header/lines).

Objetivo: que el motor soporte esto **reusando al máximo la maquinaria existente** (generador de catálogos, motor de estados, reglas PRE/POST, contrato de API) en vez de construir un subsistema paralelo.

## 2. Glosario (para evitar ambigüedad con nombres ya usados en el código)

⚠️ **Colisión de nombres a tener en cuenta**: en este proyecto `meta_schema_detail` ya significa "definición de un CAMPO de un catálogo" (columna `schema_context_field`, propiedades, etc.) — no tiene nada que ver con el "detalle" de este requerimiento. Para no pisarse, en este documento:

- **Encabezado / maestro**: el catálogo padre (ej. `pty_pedidos`). Es un `meta_schema_header` normal, sin campo `schema_encabezado_id`.
- **Catálogo detalle**: el catálogo hijo (ej. `pty_pedidos_items`). Es también un `meta_schema_header`, pero con `schema_encabezado_id` apuntando al maestro.
- **Renglón**: una FILA del catálogo detalle (un ítem del pedido).
- **Metacampos**: los campos propios de cada catálogo (`meta_schema_detail`, el de siempre) — cuando se hable de "metacampos del detalle" se refiere a los campos del catálogo detalle, no a otra cosa.

## 3. Alcance

**Incluye**: un nivel de anidamiento (maestro → N catálogos detalle). Autómata compartido entre maestro y sus detalles. Reglas PRE/POST por catálogo detalle. Contrato/documentación que incluye los detalles.

**Fuera de alcance de esta primera versión** (ver §7 preguntas abiertas): detalle multinivel (un detalle que a su vez sea maestro de otro detalle), y un maestro sin ningún catálogo detalle asociado usando este mecanismo (si no tiene detalles, es simplemente un catálogo normal, no necesita este requerimiento).

## 4. Requerimientos (16 puntos)

### R1 — Un catálogo detalle tiene siempre un único maestro
**Funcional**: cada tabla de detalle pertenece a exactamente un encabezado.
**Técnico**: nuevo campo `schema_encabezado_id` en `meta_schema_header` (FK a otro `meta_schema_header.id`, obligatorio cuando el catálogo es de tipo detalle). `CatalogoGenerador` valida que exista y esté ya generado antes de generar el detalle (mismo criterio que ya aplica hoy a campos tipo `referencia`).

### R2 — Un maestro puede tener N catálogos detalle
**Funcional**: un pedido puede tener, por ejemplo, "items" y "descuentos aplicados" como dos catálogos detalle distintos, ambos del mismo maestro.
**Técnico**: sin restricción de cantidad — cualquier cantidad de headers puede tener el mismo `schema_encabezado_id`.

### R3 — El detalle participa del mismo autómata que el maestro, en todas sus transiciones
**Funcional**: cuando el pedido cambia de estado (ej. Confirmado), sus renglones cambian de estado junto con él, como parte del mismo evento de negocio.
**Técnico**: los renglones tienen su propia columna `estado_id` (igual que hoy todo catálogo con motor de estados adoptado), pero los estados/transiciones/reglas (`meta_schema_estados/transiciones/transicion_reglas`) están definidos **una sola vez, a nivel del maestro** — no hay un autómata paralelo por catálogo detalle. `MetaStateEngine.ejecutar_transicion/3` se extiende para, dentro del mismo `Ecto.Multi`, mover el header y los renglones alcanzados por la transición al estado destino, todo o nada.

### R4 — El detalle admite bloqueo de campos por transición, igual que el encabezado
**Funcional**: cada catálogo detalle puede definir, por estado, qué campos de sus renglones son editables.
**Técnico**: reusa `editable_en` (ya existe en `schema_context_properties`) sin cambios de mecanismo — solo se aplica también a los campos del catálogo detalle.

### R5 — El detalle admite campos obligatorios parametrizables por transición
**Funcional**: por ejemplo, exigir que "cantidad" y "producto" estén completos para poder confirmar el pedido, a nivel de cada renglón.
**Técnico**: reusa la regla built-in `campos_requeridos` (ya está en el vocabulario cerrado de 8 reglas PRE) — se declara sobre transiciones del catálogo detalle igual que hoy se declara sobre el header.

### R6 — El detalle modifica el contrato final (payload) ✅
**Funcional**: al ejecutar una transición sobre el pedido, el payload deja de ser solo los campos del encabezado.
**Implementado (Fase 2/3)**: la forma real terminó siendo distinta a la propuesta original de este documento — en vez de anidar el header bajo una llave `"header"`, los campos del header se mandan SUELTOS en el body (100% igual que siempre, retrocompatible con cualquier catálogo sin detalles) y se agrega una llave reservada `"renglones": {"<catalogo_detalle>": [items...]}` — cada item es un `renglon_id` pelado (solo mueve estado) o un mapa `%{"renglon_id" => N, "<campo>" => valor}` (además edita, sujeto al `campos_editables` de esa transición). `MetaTransicionController.ejecutar/2` separa `"renglones"` del resto antes de tratarlo como contexto/edición del header.

**Hueco encontrado después de cerrar la Fase 4 y corregido**: el `POST /api/:tabla_maestro` de ALTA (crear un maestro nuevo) no tenía forma de crear sus renglones iniciales en el mismo request — había que hacer 1 POST para el encabezado y N POST más (uno por renglón) contra el catálogo detalle, dejando una ventana real donde el maestro existe sin ningún renglón. Corregido: el mismo body de creación acepta `"renglones": {"<catalogo_detalle>": [attrs, ...]}` (sin `renglon_id`, son altas nuevas) y crea encabezado + renglones en el MISMO `Ecto.Multi` — `CatalogoGenerico.crear/3`, `MetaStateEngine.dar_de_alta/5`/`ejecutar_nucleo_alta/4`, y `MetadataApp.Renglones.crear_todos/3` (reusa `CatalogoGenerico.crear/2` por renglón — mismo lock/asignación de `renglon_id`/`estado_id` heredado que ya resolvía `preparar/3`). Todo o nada: un renglón inválido revierte también el encabezado. `POST` batch (body = lista) también lo soporta, un `"renglones"` por item. Verificado con HTTP real: alta con 2 renglones en un solo request, rechazo de un renglón inválido sin dejar el encabezado huérfano, y creación sin `"renglones"` sin cambios (regresión).

### R7 — El detalle modifica la documentación del contrato ✅
**Funcional**: la doc de API por transición (pestaña API en `BcMotorLive`) debe mostrar también la forma del/los array(s) de detalle que esa transición acepta, no solo los campos del header.
**Implementado**: `panel_api` arma `catalogos_detalle` (nombre + campos de cada detalle del maestro) y `ejemplo_transicion/6` separa `campos_editables` por dueño real (header vs. cada catálogo detalle — nunca por prefijo de string) para armar el payload de ejemplo con `"renglones"` cuando corresponde. Bug real encontrado y corregido en el camino: la versión anterior de `ejemplo_transicion/5` metía CUALQUIER campo de `campos_editables` (incluidos los de un catálogo detalle) directo en el payload del header — documentaba un contrato que nunca hubiera funcionado.

### R8 — El detalle participa en reglas PRE/POST propias
**Funcional**: el equipo de Lógica de Negocio puede escribir reglas de negocio sobre los renglones (ej. "la cantidad no puede ser mayor al stock disponible"), con el mismo patrón que ya usan para el header.
**Técnico**: mismo mecanismo de resolución por convención (`MetadataApp.MetaBusinessProcess.Reglas.<CatalogoDetalle>.<Regla>`) — cada catálogo detalle tiene su propio namespace de reglas, sin coordinación extra. Estas reglas corren **por renglón**, dentro del mismo ciclo de la transición del maestro (ver R15).

### R9 — El detalle tiene sus propios metacampos, igual que el encabezado
**Funcional**: cada catálogo detalle define sus propios campos de negocio (producto, cantidad, precio, etc.), independientes de los del maestro.
**Técnico**: un catálogo detalle es, en los hechos, un `meta_schema_header` + `meta_schema_detail` (campos) completo — no hay estructura nueva, reusa 100% el generador existente.

### R10 — Los metacampos de cada catálogo detalle se envían en el contrato ✅
**Funcional**: quien consume la API tiene que poder saber qué campos tiene cada detalle sin adivinar.
**Implementado**: `GET /api/:tabla` y `GET /api/:tabla/:id` agregan `"meta_campos_detalle": {"<catalogo_detalle>": [...]}` junto a `meta_campos` — nueva `MetaSchemaContext.meta_campos_por_detalle/1`. Solo aparece cuando el catálogo de verdad tiene detalles (`%{}` se omite entero) — un catálogo normal (la enorme mayoría) devuelve exactamente el JSON de siempre, sin cambios.

### R11 — El TRN es solo a nivel encabezado
**Funcional**: no hace falta una referencia transaccional por renglón — el pedido completo es "la operación".
**Técnico**: ya resuelto por diseño (Fase 1-3 del TRN, ya implementado). Los catálogos detalle nunca llevan `trn`/`ulid` propios ni se marcan `schema_es_transaccional`; su trazabilidad es a través de `schema_encabezado_id` → el TRN del maestro.

### R12 — Nada de soft-delete en el detalle; solo transición a un estado tipo "Cancelado"
**Funcional**: un renglón nunca se borra técnicamente — si el usuario de negocio quiere anularlo, pasa por una transición del autómata a un estado que la definición de negocio decida llamar "Cancelado" (o el nombre que corresponda), quedando su historial completo.
**Técnico**: `CatalogoGenerico.eliminar/2` (soft-delete vía `delete_guid`) se deshabilita explícitamente para catálogos con `schema_encabezado_id` seteado — el `DELETE` de la API genérica responde con error para estos catálogos. El único camino para "sacar" un renglón es una transición común y corriente, no un mecanismo aparte.

### R13 — Los campos del detalle se pueden editar, eliminar o agregar libremente
**Funcional**: la definición de un catálogo detalle puede evolucionar igual que cualquier otro catálogo.
**Técnico**: ya resuelto — `CatalogoGenerador.asegurar_campos_nuevos/1` ya soporta ALTER TABLE sobre un catálogo existente sin mecanismo nuevo, porque un catálogo detalle es un catálogo más para el generador.

**Agregado 2026-07-23 — campo obligatorio con "Valor por default" (aplica a CUALQUIER catálogo existente, no solo detalle, pero se documenta acá porque R13 es donde vive "agregar campos a un catálogo que ya existe")**:

**El problema**: agregar un campo a un catálogo cuya tabla ya tiene filas (potencialmente millones) es distinto de agregarlo en la creación (tabla vacía). Un `ALTER TABLE ... ADD COLUMN x NOT NULL` sin default es directamente imposible en Postgres si la tabla tiene filas — no hay valor que ponerles a las filas viejas.

**Comportamiento de siempre (sigue siendo el default si no se completa el valor)**: `CatalogoGenerador.agregar_columnas/2` genera la columna con `null: true` sin importar si el campo está marcado "Opcional" o no — lo "obligatorio" pasa a exigirse solo a nivel aplicación (`validate_required` del changeset) para altas/ediciones de acá en adelante. Las filas viejas quedan con `NULL` en esa columna hasta que alguien las edite.

**Nuevo, opt-in**: el modal "Agregar campo" de `BcMotorLive` (el único lugar donde se agregan campos a un catálogo YA generado — `BcNuevoCompletoLive` es un catálogo nuevo, tabla vacía, no le aplica este problema) ofrece un campo **"Valor por default"**, visible solo cuando el tipo no es `referencia` y el campo no es opcional. Si se completa:
- La migración generada usa `null: false, default: <valor>` — una restricción NOT NULL real, no solo de palabra.
- Postgres 11+ guarda un default **constante** como metadata del catálogo en vez de reescribir la tabla fila por fila — la migración es instantánea aunque la tabla tenga millones de registros, sin ventana de bloqueo larga. Las filas viejas reciben el valor default de inmediato (confirmado con `SELECT` real después de la migración, no solo con el DDL).
- **Referencia nunca ofrece este campo**: no hay un valor razonable — inventar una FK significaría enganchar a ciegas todas las filas viejas a un mismo registro ajeno. Se mantiene siempre `null: true`, sin cambios.
- **Validación en dos capas** (`BcMotorLive.valor_default_valido?/2` + `CatalogoGenerador.formatear_default/2`, esta última "defensa en profundidad" porque escribe código Elixir fuente a disco que después se compila y corre como migración): `string`/`date` usan `inspect/1` (siempre produce un literal Elixir escapado, seguro sin importar el contenido); `integer`/`decimal`/`boolean` se validan con regex ANTES de insertarse sin comillas en el archivo — un valor que no matchea nunca llega a escribirse, la columna cae al fallback nullable de siempre en vez de escribir texto sin validar (que sería, en los hechos, ejecutar lo que sea que alguien haya puesto ahí).

**Verificado de punta a punta** con un catálogo descartable con filas ya insertadas: (1) default entero válido → columna `NOT NULL` real, filas viejas backfileadas al valor; (2) sin default → comportamiento de siempre, sin cambios; (3) un valor deliberadamente malicioso para un campo `integer` (con código Elixir embebido) → nunca llegó a escribirse en el archivo de migración, la columna cayó al fallback nullable, el proceso siguió vivo; (4) default de texto con comillas → escapado correctamente vía `inspect/1`, filas viejas backfileadas.

### R14 — `renglon_id` autoincremental por maestro, control por ítem
**Funcional**: cada renglón de un catálogo detalle tiene un número de línea que empieza en 1 para cada maestro (pedido #100 → renglones 1,2,3 / pedido #101 → renglones 1,2,3 de nuevo), como control de ítem legible para el usuario de negocio.
**Decisión tomada (14.a)**: se mantiene el `id` técnico de siempre (bigint autoincremental de Postgres) como PK real de la tabla — **no** se pasa a PK compuesta. Se agrega `renglon_id` (integer, NOT NULL) más un índice único compuesto `(encabezado_id, renglon_id)`. Motivo: todo el motor (`CatalogoGenerico`, el lock optimista de `MetaStateEngine`, TRN, reglas vía `entity_id`) asume una PK escalar `id` — reusarla evita tocar esa maquinaria. El límite de 64 bits del `id` (~9.2 × 10¹⁸) hace que el desborde no sea un riesgo real (confirmado: el generador ya usa `bigint`, no `serial` de 32 bits).
**Técnico — asignación de `renglon_id`**: se calcula dentro de la misma transacción de creación del renglón, con lock a nivel del maestro (`SELECT ... FOR UPDATE` sobre el header, o un `MAX(renglon_id) + 1` protegido por el mismo lock optimista que ya usa el motor de estados) para evitar carrera entre dos inserts concurrentes de renglones del mismo pedido.

### R15 — El autómata permite mover 1 o más renglones por transición, con validación por ítem
**Funcional**: una transición del pedido puede aplicar a todos sus renglones o solo a un subconjunto, según lo que el usuario/proceso indique, y cada renglón se valida individualmente.
**Técnico**: el caller de la transición manda explícitamente la lista de `renglon_id`s en alcance (no se asume "todos los renglones del maestro" por default). Las reglas PRE corren por cada renglón de esa lista; si CUALQUIER renglón falla, se rechaza la transición completa — mismo criterio "todo o nada" que ya rige el resto del motor (sin commits parciales). Los permisos (`requiere_rol`) se siguen evaluando a nivel de transición, no por renglón.

### R16 — Cómo se identifica si un catálogo es maestro/detalle o un catálogo genérico
**Funcional**: al ver un catálogo (en el listado de BC, en la doc de API, etc.) tiene que quedar claro si es un catálogo plano de siempre, un maestro, o un detalle de otro.
**Decisión tomada**: **no** se agrega un tercer valor a `schema_context_type` (ej. `= 3`) para esto. Ese campo ya tiene un significado propio y ortogonal — `1` = catálogo con tabla física, `2` = carpeta (nodo de navegación sin datos) — mismo criterio que ya se aplicó en el diseño del TRN, donde se descartó explícitamente reusar `schema_context_type` para marcar "transaccional" y en su lugar se agregó un campo booleano aparte (`schema_es_transaccional`). Mezclar "es carpeta" con "es maestro/detalle" en el mismo enum haría que un solo campo cargue dos decisiones de diseño distintas, con el riesgo de estados inválidos (ej. `type = 3` pero `schema_encabezado_id` nulo).
**Técnico**: la identidad ya está resuelta por R1 sin campo nuevo:
- **Es detalle** ⇔ `schema_encabezado_id` no es nulo (dato directo, ya definido en R1).
- **Es maestro** ⇔ existe algún otro header con `schema_encabezado_id` apuntando a este — se calcula con un `EXISTS`/`join`, no se guarda. Mismo patrón que ya usa `MetaSchemaContext` para `es_carpeta: h.schema_context_type == 2` (un booleano derivado en tiempo de lectura, no una columna).
- **Es catálogo genérico** (el caso de siempre) ⇔ no es ni maestro ni detalle — no necesita ninguna marca nueva, es simplemente la ausencia de las dos condiciones de arriba.

## 5. Modelo de datos — resumen

- `meta_schema_header` gana `schema_encabezado_id` (FK nullable a `meta_schema_header.id`; no-nulo implica "soy un catálogo detalle").
- Cada tabla física de un catálogo detalle gana:
  - `renglon_id` (integer, not null) — control de ítem, único por maestro.
  - `estado_id` — ya existe hoy como campo de sistema para cualquier catálogo con motor adoptado, sin cambios.
  - **Sin** `trn`/`ulid` (R11).
  - Índice único compuesto `(encabezado_id, renglon_id)`.
- `id` sigue siendo la PK física de siempre (bigint), sin cambios (R14.a).
- `schema_context_type` **no se toca** (sigue siendo solo `1` = catálogo / `2` = carpeta) — "es maestro"/"es detalle" se resuelven vía `schema_encabezado_id`, directo o derivado, nunca con un tercer valor de tipo (R16).

## 6. Piezas del motor que este requerimiento toca

- `MetadataApp.BusinessProcessBuilder.MetaSchema.Header` — nuevo campo `schema_encabezado_id`.
- `MetadataApp.BusinessProcessBuilder.MetaSchemaContext` — nuevo helper derivado `es_maestro?/1` (mismo patrón que `es_carpeta`), sin columna nueva (R16).
- `MetadataApp.BusinessProcessBuilder.CatalogoGenerador` — generar `renglon_id` + índice único + lógica de asignación con lock; validar que el maestro exista antes de generar el detalle.
- `MetadataApp.MetaStateEngine` — extender `ejecutar_transicion/3` para mover header + renglones en un mismo `Multi`; aceptar lista de `renglon_id`s en alcance.
- `MetadataApp.MetaEstadosAdmin` / `meta_schema_estados/transiciones/transicion_reglas` — confirmar que quedan asociados al maestro, no a cada catálogo detalle.
- `Reglas.modulo_negocio/2` (resolución de reglas PRE/POST) — sin cambio de mecanismo, solo se invoca también para catálogos detalle.
- `MetadataApp.BusinessProcessBuilder.CatalogoGenerico` — bloquear `eliminar/2` para catálogos con `schema_encabezado_id` (R12).
- `MetadataAppWeb.BusinessProcessBuilder.CatalogoController` / `MetaTransicionController` — payload compuesto (R6), meta_campos por detalle (R10).
- `MetadataAppWeb.Sysadmin.BcMotorLive` — documentación de API por transición incluyendo el/los detalle(s) (R7); UI de definición del catálogo detalle (marcarlo como detalle de X al crearlo).
- `MetadataAppWeb.CatalogoLive` — popup interno (`detalle_modal/1`) con encabezado + grilla por catálogo detalle, selección de renglones por checkbox, alta de renglones, y botones de transición que aplican a la selección.

## 7. Preguntas abiertas (no resueltas en este documento)

1. **Multinivel**: ¿un catálogo detalle puede a su vez ser maestro de otro catálogo detalle (ej. pedido → items → sub-componentes)? Propuesta: fuera de alcance v1, revisar si aparece un caso de negocio real.
2. **Alta del maestro sin detalle todavía**: ¿se puede crear/transicionar el encabezado sin ningún renglón, o el autómata exige al menos 1 renglón para ciertas transiciones (ej. no se puede "Confirmar" un pedido sin items)? Propuesta: modelarlo como una regla PRE de negocio (`sin_relacionados`/equivalente ya existe como vocabulario), no como restricción dura del motor.
3. ✅ **UI de edición combinada** (encabezado + grilla): resuelto — popup interno sobre `CatalogoLive` (decisión explícita del usuario, no pantalla con ruta propia), ver Fase 5 en §8.

## 8. Fases sugeridas de implementación

1. ✅ **Modelo + generador**: `schema_encabezado_id`, `renglon_id` + índice único, asignación con lock, bloqueo de `eliminar/2`. Verificado de punta a punta con catálogos descartables.
2. ✅ **Motor de estados compartido**: `MetaStateEngine.ejecutar_transicion/4` mueve header + renglones en el mismo `Ecto.Multi` (todo o nada), con lista de `renglon_id`s en alcance por catálogo detalle (`opciones[:renglones]`). Cada renglón corre sus PROPIAS reglas PRE/POST (dispatch automático por struct, sin cambios al mecanismo de `Reglas`). Verificado con rechazo por precondición de un renglón (nada cambia, ni el header) y con una confirmación real que mueve header + 2 renglones juntos, con su historial de eventos correcto. **Hallazgo corregido en el camino**: los renglones nacían con `estado_id: nil` (`MetaStateEngine.estado_inicial/1` busca estados en el header del catálogo DETALLE, que nunca los tiene) — se corrigió en `MetadataApp.Renglones` para que un renglón nazca con el estado ACTUAL del maestro, leído en el mismo lock que ya evita la carrera de `renglon_id`. Fase 2 todavía NO aplica `campos_editables` a los renglones (eso es Fase 3, R4/R5) — la transición compartida solo mueve `estado_id`.
3. ✅ **Reglas y campos obligatorios/editables por renglón**. Corrección respecto al plan original: el mecanismo real NO es `editable_en` (deprecado desde el rediseño de reglas 2026-07-21) sino `Transicion.campos_editables` — se extendió `opciones[:renglones]` de `ejecutar_transicion/4` para aceptar, por ítem, un `renglon_id` pelado (solo mueve estado) o un mapa `%{"renglon_id" => N, "<campo>" => valor}` (R4: además edita ese campo, sujeto al MISMO `campos_editables` de la transición — reusa `construir_changeset_transicion/3` sin duplicar la whitelist, porque ya deriva el catálogo del struct). Se corrigió `MetaEstadosAdmin.validar_campos_editables/1`, que solo aceptaba campos del catálogo del header — ahora también acepta campos de cualquiera de sus catálogos detalle (nueva `MetaSchemaContext.listar_catalogos_detalle/1`). R5 (campos obligatorios) no necesitó código nuevo: el PRE de un catálogo detalle ya puede llamar `MetaStateEngine.Reglas.Pre.evaluar("campos_requeridos", registro, contexto, %{"campos" => [...]})`, mismo helper que cualquier catálogo — es una convención a documentar, no una capacidad del motor por construir. Verificado con edición real de un campo de un renglón (mueve Y edita en el mismo update atómico) y con el rechazo (todo o nada) de un campo fuera de la whitelist.
4. ✅ **Contrato y documentación**: `"renglones"` en el payload de transición (R6), `meta_campos_detalle` en GET/discovery (R10), doc de API por transición separando campos header/detalle (R7). Verificado con un maestro+detalle real vía HTTP: `GET /api/:tabla` real con `meta_campos_detalle`, y la pestaña API de `BcMotorLive` renderizando la nota y el ejemplo de `"renglones"` sin error. **Gotcha operativo, no relacionado al código de esta fase**: en Windows sin symlinks, `Phoenix.Ecto.CheckRepoStatus` compara contra la copia de `priv/` en `_build`, que queda desactualizada frente a migraciones nuevas escritas por el generador hasta el próximo `mix compile` que la resincronice — mismo mecanismo ya documentado en `CatalogoGenerador.migrar/0`, pero ese plug de Phoenix no tiene el mismo workaround.
5. ✅ **UI**: popup interno sobre `CatalogoLive` (decisión explícita, no pantalla con ruta propia) — encabezado solo lectura + botones de transición disponibles (reusa `transiciones_disponibles/2` sin cambios), una grilla por catálogo detalle con checkbox por renglón + "Agregar renglón" (form dinámico según el tipo de cada campo), transición ejecutada con la selección armada como `renglones: %{"catalogo" => [renglon_id,...]}`. La celda ID de `CatalogoLive` pasa a ser un botón solo cuando el catálogo es maestro (`@es_maestro?`) — sin cambios visuales para el resto. **Sin editar campos de renglón durante la transición desde esta UI todavía** (el backend ya lo soporta desde Fase 3 — R4 — queda como extensión futura, no pedida para esta fase). **Verificación**: sin navegador headless disponible en esta máquina (mismo gotcha ya documentado en sesiones anteriores del proyecto) ni `lazy_html` instalado (requerido por `Phoenix.LiveViewTest` para simular clics, deliberadamente no agregado como dependencia solo para esto) — se verificó en cambio invocando `CatalogoLive.render/1` directo con assigns armados a mano simulando el modal abierto con datos reales, forzando la ejecución completa del template (incluyendo `detalle_modal/1` y `campo_input/1`) sin excepciones, más la carga real por HTTP de la página cerrada (botón visible solo en catálogos maestro, ausente en el resto).

Mismo criterio que ya se usó para TRN: cada fase se implementa, se muestra y se verifica de punta a punta antes de pasar a la siguiente. **Las 5 fases del plan original están completas.**
