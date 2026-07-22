# CompliancePty — reglas de cumplimiento para construir dentro de PrettyCore

Estas son las reglas que **toda transacción y todo catálogo maestro nuevo** dentro de PrettyCore tiene que cumplir, para que lo que se construya sea consistente con lo que ya existe — no son sugerencias, son el mínimo para que algo nuevo "encaje" en el motor sin generar deuda ni excepciones a mano. Cada regla dice qué exige, por qué, y qué mecanismo del motor ya la resuelve (para no reinventarla) o falta configurar.

**Fuera de alcance de este documento, a propósito**: profiles/roles/permisos — se agregan a futuro, no está resuelto todavía. `MetadataApp.MetaPermissions.can?/3` existe como stub mínimo (`requiere_rol` en las reglas PRE/POST), pero no hay un sistema de sesión/roles real detrás todavía. No lo asumas resuelto al construir algo nuevo.

## C1 — Toda transacción debe soportar lotes (batch)

**Qué exige**: se tiene que poder dar de alta más de un registro en un solo request, no uno por uno.

**Ya resuelto por el motor, gratis**: `POST /api/:tabla` acepta el body como objeto (un registro) o como **lista** (batch) — `CatalogoGenerico.crear_muchos/2`. Todo o nada: si un item del lote falla, se revierten todos. Si el catálogo es maestro de un detalle, cada item del lote puede traer su propia `"renglones"` (un lote de maestros, cada uno con sus propios renglones iniciales).

**Qué tenés que hacer vos**: nada — cualquier catálogo generado por el motor ya soporta esto. No hace falta código a medida.

## C2 — Debe ser atómica

**Qué exige**: una operación de negocio (alta, transición, alta con renglones, batch) no puede quedar "a medias" — o se aplica todo o no se aplica nada.

**Ya resuelto por el motor**: todo el ciclo de escritura corre dentro de un único `Ecto.Multi`/`Repo.transaction` — `CatalogoGenerico.crear/3`, `MetaStateEngine.ejecutar_transicion/4`, `MetaStateEngine.dar_de_alta/5`. Un `Repo.transaction` anidado dentro de otro ya activo (ej. crear un renglón desde adentro del alta del maestro) no abre una transacción real aparte — Ecto lo aplana, participa de la misma atomicidad.

**Qué tenés que hacer vos**: si una operación de negocio necesita tocar más de una tabla (ej. "al confirmar el pedido, descontar stock"), hacelo desde una regla **POST** (`MetadataApp.MetaStateEngine.Reglas.<Catalogo>.Post`, vía `MetadataApp.MetaBcCliente`) — corre dentro de la MISMA transacción del motor, nunca como un request HTTP aparte después. Un segundo request nunca es atómico con el primero.

## C3 — Debe tener un TRN en su encabezado

**Qué exige**: toda operación transaccional (venta, cobro, confirmación de pedido, etc.) tiene una referencia única, legible y trazable — el TRN (`CCCC-YYMMDD-HHMMSS-RRRR`).

**Ya resuelto por el motor**: marcá el catálogo `schema_es_transaccional: true` + un `codigo_trn` de 4 letras (ej. `VENT`) al crearlo — `MetadataApp.TRN.asignar_si_transaccional/1` corre automáticamente en cada alta, nunca hay que llamarlo a mano. Regla #1 del TRN: ninguna operación transaccional nace sin uno. Regla #3: es inmutable, ningún PATCH puede tocarlo.

**Si el catálogo es maestro de un detalle**: el TRN va **solo en el encabezado**. El detalle nunca genera el suyo propio — viaja trazado por `encabezado_id` hacia el TRN del maestro. No marques un catálogo detalle como `schema_es_transaccional`.

**Qué tenés que hacer vos**: decidir, al crear el catálogo, si es una "operación" real de negocio (necesita TRN) o un catálogo de datos maestros sin ciclo transaccional (ej. un catálogo de "clientes" no necesita TRN, un "pedido" sí).

## C4 — Debe documentarse el contrato

**Nota agregada tras una pregunta real de usuario**: `GET /api/:tabla` acepta filtros por query string sobre cualquier campo real (de sistema o de negocio) — ej. `GET /api/pty_pedido_det?encabezado_id=123` trae todos los renglones de un pedido puntual, `?estado_id=...` filtra por estado, etc. Es igualdad exacta (nada de rangos/ilike, eso queda para la UI admin de `CatalogoLive`). Antes de esto, el `GET` genérico solo paginaba — no había forma de consultar "todos los renglones de X" sin traer la tabla completa.

**Qué exige**: cualquiera que consuma la API tiene que poder ver, sin preguntar, qué endpoints existen, qué payload esperan y qué devuelven.

**Ya resuelto por el motor**: la pestaña **Contrato** de `BcMotorLive` genera la documentación completa a partir de la metadata real del catálogo (campos, estados, transiciones, `campos_editables`, `meta_campos_detalle` si es maestro) — nunca es texto escrito a mano que se desactualiza. Si el catálogo es maestro de un detalle, el contrato del **maestro** documenta también el detalle (payload de alta atómica con `"renglones"`, `meta_campos_detalle` en el GET, `"renglones"` en las transiciones). Un catálogo **detalle** no tiene pestaña Contrato propia — no es un recurso REST independiente, se documenta dentro del maestro.

**Qué tenés que hacer vos**: nada extra si usás el generador — la doc sale sola. Lo único que podés romper es dejar campos sin `"etiqueta"` en `schema_context_properties` (la doc igual funciona, pero queda menos legible).

## C5 — Todo maestro debe tener: estados, transiciones, reglas, menú de navegación, estado inicial

**Qué exige**: un catálogo maestro (uno que gobierna su propio ciclo de vida — no es detalle de otro) tiene que llegar a producción con su autómata completo, no a medio armar.

**Ya resuelto por el motor**: `MetaEstadosAdmin.completitud/1` y `validar_motor/1` son el gate automático — el botón "Guardar BC" no se habilita si falta algo de esto:
- **Estado inicial**: el primer estado que se crea se fuerza `es_inicial: true` automáticamente (`MetaEstadosAdmin.crear_estado/1`) — no hace falta acordarse de marcarlo.
- **Estados**: al menos uno.
- **Transiciones**: al menos una transición de alta (`accion: "alta"`, `estado_origen_id: nil`) o un estado inicial.
- **Reglas**: PRE/POST pueden quedar como stub (`#ESCRIBA SU CODIGO AQUÍ`), pero tienen que estar **compiladas**, no pendientes.
- **Menú de navegación**: `schema_visible: true` + `schema_context_nav` — sin esto el catálogo existe pero nadie lo encuentra en el sidebar.

**Excepción explícita — catálogo detalle**: un catálogo marcado "Detalle de X" está **exento** de estados/transiciones propias (comparte el autómata del maestro, R3 del [[catalogo-maestro-detalle-requerimientos]]) — `completitud/1` ya lo sabe (`es_detalle: true`) y no se lo exige. Sí sigue necesitando campos y, si aplica, reglas PRE/POST propias.

**Qué tenés que hacer vos**: al diseñar un catálogo nuevo, decidir primero si es un **maestro** (autómata propio) o un **detalle** (comparte el de otro) — es la pregunta que determina qué te va a pedir el wizard.

## C6 — Todo dato que el usuario cambie debe pasar por la transacción del motor

**Qué exige**: ningún campo se edita "a mano" por fuera del ciclo de reglas/atomicidad — es el principio que sostiene C2 (atomicidad) y C4 (contrato documentado): si existe un camino que edita datos sin pasar por ahí, esos dos ya no son ciertos de verdad, son ciertos "la mayoría de las veces".

**Bug real encontrado en producción y corregido**: `PUT/PATCH /api/:tabla/:id` sobre un catálogo **detalle** editaba cualquier campo libremente, sin transición, sin `campos_editables`, sin evento de auditoría. La causa: `MetaStateEngine.campos_editables/2` decide si un catálogo "adoptó el motor" mirando si **su propio** header tiene `meta_schema_estados` — y un catálogo detalle nunca los tiene (viven en el maestro, R3), así que lo trataba como catálogo sin motor y no restringía nada. Todo el trabajo de C5/R4 (picker de campos editables por transición) era bypasseable con un simple `PUT`.

**Ya resuelto por el motor**: `CatalogoGenerico.actualizar/2` ahora rechaza de entrada cualquier `PUT/PATCH` sobre un registro cuyo catálogo tenga `schema_encabezado_id` — mismo criterio que ya bloqueaba el `DELETE` (R12). La única forma de editar un campo de un renglón es una transición del maestro con `"renglones"` (R4) — atómica, auditada (`meta_schema_transicion_eventos`), sujeta a `campos_editables`.

**Qué tenés que hacer vos**: si en algún momento un catálogo (detalle o no) necesita una forma nueva de que el usuario cambie un dato, primero preguntate "¿esto entra al ciclo del motor (transición/regla), o es un atajo que lo bypassea?" — si es lo segundo, es un hueco de compliance, no una funcionalidad.

## Checklist rápido al crear algo nuevo en PrettyCore

1. ¿Es una operación transaccional real (necesita TRN)? → `schema_es_transaccional: true` + `codigo_trn`.
2. ¿Es maestro de un detalle, o es el detalle de otro? → si es detalle, marcalo "Detalle de X" (no le definas estados/transiciones propias).
3. Si es maestro: al menos 1 estado (el primero ya nace inicial), al menos la transición "alta", campos definidos, `schema_visible: true` + nav.
4. Reglas PRE/POST: compilalas aunque sea con el stub — no las dejes pendientes si vas a "Guardar BC".
5. No inventes un flujo de "2 requests" para una operación que debería ser una sola — si hace falta, es señal de que el motor necesita una extensión (como ya pasó con la alta atómica de renglones), no de resolverlo en el cliente.
6. Dejá que el Contrato se documente solo — no escribas documentación de API aparte.
7. Si necesitás editar un campo de un renglón, es por transición del maestro con `"renglones"` — nunca `PUT/PATCH` directo al catálogo detalle (bloqueado a propósito, C6).
