# SPEC-SYS-0109202601 — Administrador de Folios de Transacciones

**Documento:** Design · **Fase:** ✅ aprobada (2026-09-01) — ver
`tasks.md` para la siguiente fase.

## 1. Arquitectura de integración

### 1.1 Punto de enganche

Toda alta de un registro transaccional pasa por
`CatalogoGenerico.crear_con_attrs_preparados/5`
(`lib/metadata_app/business_process_builder/catalogo_generico.ex:287`),
que bifurca en dos caminos según si el catálogo adoptó el motor de
estados:

- **Sin motor de estados** → `crear_simple/3` — ya envuelve el insert
  en `Repo.transaction(fn -> ... end)`.
- **Con motor de estados** → `MetaStateEngine.ejecutar_nucleo_alta/4`
  — ya usa `Ecto.Multi` (`Multi.insert(:registro, ...) |>
  Multi.insert(:evento, ...) |> Multi.run(:renglones, ...) |>
  Repo.transaction(multi)`).

Ambos ya son atómicos por su cuenta — no hace falta inventar ninguna
transacción nueva, alcanza con sumarles un paso más DENTRO de la que
ya existe.

### 1.2 TRN + Folio se unifican en un solo paso atómico (decisión, 2026-09-01)

**Hoy** (`crear_con_attrs_preparados/5`, líneas 315-323): TRN se asigna
DESPUÉS de que el camino elegido ya terminó y confirmó — es un
`Repo.transaction` SEPARADO que hace `UPDATE` sobre el registro ya
insertado. Documentado como una no-atomicidad aceptada a propósito
("Sin ventana observable desde afuera... crear/2 no devuelve el
registro hasta que esto termina").

**R7 exige más que eso para folio**: folio y documento tienen que
revertirse juntos como una sola operación. En vez de sostener DOS
modelos de atomicidad distintos para los dos identificadores de un
mismo registro (TRN blando, folio estricto), la decisión es unificar:
**TRN y folio se asignan juntos, dentro de la MISMA transacción que
crea el registro** — mueve la asignación de TRN de "paso posterior" a
"parte del `Ecto.Multi`/`Repo.transaction` de creación".

Esto es un cambio de comportamiento a una feature YA en producción
(TRN, Fase 1) — no es exclusivo de esta spec, se anota acá porque nace
como consecuencia directa de R7, a pedido explícito.

**Qué SÍ se mueve adentro de la transacción de creación:**
- Asignación de TRN/ULID (`MetadataApp.TRN`)
- Asignación de Folio (este spec)

**Qué NO se mueve** (fuera de alcance de este cambio, quedan como
pasos posteriores tal cual están hoy):
- `estampar_campos_alcance_post_insert/3` (branch/sales_unit/inventory
  para el camino con motor de estados)
- `auditar_alta/3` (log de auditoría de datos, `MetaAuditoria`)

**Consecuencia práctica**: el `MetadataApp.TRN.asignar_si_transaccional/1`
que hoy corre suelto en `crear_con_attrs_preparados/5` se retira de
ahí — la asignación de TRN pasa a vivir donde vive folio (ver §2), y
ambas se invocan desde los dos puntos de enganche (§1.1) contra una
única función compartida, no lógica duplicada dos veces.

**Riesgo a vigilar en Tasks**: `TRN.asignar/3` reintenta hasta 5 veces
si el TRN generado colisiona (aleatorio + mismo segundo) — correr ese
reintento DENTRO de una transacción más larga (que ahora también
incluye folio, renglones, eventos de transición, postcondición) alarga
un poco la ventana de la transacción. Aceptable dado que la colisión es
rarísima (probado hoy con 5 reintentos en producción), pero vale un
test de regresión explícito para no perder cobertura de ese camino.

## 2. Modelo de datos

**Dependencia asumida**: "Subtipo" (R1, Glosario) todavía no tiene
catálogo propio ("Subtipos de Transacciones", columna estándar
`subtipo_transaccion` en el catálogo transaccional) — ese catálogo es
de OTRA spec, no de esta. Acá solo asumimos que, cuando exista, el
valor que guarda cualquier registro transaccional en su columna
`subtipo_transaccion` es un id entero (igual que cualquier campo
`referencia` de este sistema) — el perfil de numeración guarda ESE id,
sin depender de cómo se implemente el catálogo de Subtipos.

**Regla acotada al implementar ese catálogo (2026-09-01, a pedido
explícito)**: `subtipo_transaccion` se tipa `referencia` (con FK real
al catálogo de Subtipos) **si y solo si** el catálogo dueño de la
columna tiene `schema_es_transaccional: true`. `pty_folio_perfiles`
(este spec, §6) NO califica — su propio campo `subtipo_transaccion` es
config (a qué subtipo aplica el perfil), no un documento transaccional
en sí, y queda como `integer` simple sin FK. Nota técnica (ver
`CatalogoGenerador.asegurar_campos_nuevos/1`,
catalogo_generador.ex:378-385): retipar a `referencia` una columna que
YA existe físicamente solo actualiza metadata — nunca agrega el FK
real con `ALTER TABLE`. Un catálogo transaccional que adopte
`subtipo_transaccion` después de creado necesitaría ese FK agregado a
mano (migración puntual) si se quiere la integridad real, no solo el
combo en la UI.

**Catálogo "Subtipos de Transacción" (R8, construido 2026-09-01)**:
`pty_subtipos_transaccion` — BC real, campos `tipo_transaccion`
(`referencia` → `meta_schema_header`, obligatorio — así cada subtipo
queda scopeado a UN catálogo, ej. sales_order/cotiza,
sales_order/pedido, reciep_order/remision) y `descripcion` (`string`).
Con autómata propio (a diferencia de `folio_perfiles`, §6): Activo
(inicial) → Baja, sin reactivación (no se pidió).
`IdentificadoresTransaccionales.asignar_folio/3` corta ANTES de tocar
el perfil (sin lock, sin incremento) si el `subtipo_transaccion` del
registro está en el estado Baja — `verificar_subtipo_activo/2` compara
el `estado_id` actual del subtipo contra el `estado_destino_id` de SU
transición `accion: "baja"` (no por nombre de estado, para no ser
frágil ante un rename). `nil` (sin subtipo) pasa de largo.

### 2.1 Tabla `folio_perfiles` — configuración + contador vivo (una sola tabla)

Config y contador conviven en la misma fila a propósito: sin política
de reinicio (Requirements §2 — resuelto, no hay reinicio automático),
no existe la noción de "varios contadores en el tiempo para el mismo
perfil" que en un diseño anterior justificaba separarlos. Esta fila es
también la que se bloquea con `SELECT ... FOR UPDATE` al pedir folio
(R3 — unicidad bajo concurrencia).

| Columna | Tipo | Notas |
|---|---|---|
| `id` | — | |
| `meta_schema_header_id` | FK → `meta_schema_header` | Tipo de transacción (R1) |
| `subtipo_transaccion_id` | integer, nullable | Ver dependencia asumida arriba. `nil` = el perfil aplica a TODO el catálogo sin distinguir subtipo |
| `branch_id` | FK → Sucursal, nullable | Granularidad (R1): `nil` = folio global, valor = folio independiente por esa sucursal |
| `serie` | string(4) | Validado por R1a |
| `numero_actual` | integer | Contador vivo — fila que se bloquea con `FOR UPDATE` en cada asignación |
| `numero_inicial` | integer | Con qué arrancó este perfil (R1) — se conserva para referencia, no se vuelve a usar después del primer folio |
| `insert_guid` / `update_guid` / `delete_guid` | string | Convención estándar del sistema |

**Unicidad**: `(meta_schema_header_id, subtipo_transaccion_id, branch_id)` única entre perfiles activos (`delete_guid IS NULL`) — dos perfiles para la misma combinación exacta serían ambiguos (¿cuál usar al pedir folio?).

### 2.2 Tabla `folio_historial` — ledger de asignaciones (R6)

Append-only: una fila por cada folio asignado alguna vez, para
siempre. Nunca se actualiza ni se borra — a diferencia de mi intento
anterior (descartado), acá NO hace falta un campo "anulado" ni función
`anular/1`: R4 ya deja claro que el folio no se libera pase lo que
pase con la transacción, así que el ledger no necesita reflejar ningún
cambio de estado — solo el hecho inmutable de que se asignó.

Se inserta en el MISMO paso atómico que folio + TRN (§1.2) — por eso
SÍ puede guardar el `trn` directamente (a diferencia del diseño
anterior, que lo separaba porque TRN se asignaba en otro momento).

| Columna | Tipo | Notas |
|---|---|---|
| `id` | — | |
| `folio_perfil_id` | FK → `folio_perfiles` | |
| `meta_schema_header_id` | FK → `meta_schema_header`, denormalizado | Consulta directa sin join, y estable aunque el perfil cambie después |
| `subtipo_transaccion_id` | integer, nullable, denormalizado | |
| `branch_id` | FK, nullable, denormalizado | |
| `serie` | string(4), denormalizado | Congelado al momento de asignar — si el perfil edita su Serie después, el historial viejo no cambia |
| `folio` | integer | El número asignado |
| `entity_id` | integer | El id de la transacción real (fila del catálogo transaccional) |
| `trn` | string | El TRN de la misma transacción — ya disponible porque se asignan juntos (§1.2) |
| `inserted_at` | timestamp | Cuándo — sin `updated_at`, esta tabla nunca se edita |

No hay `idempotency_key` ni mecanismo de reintento-seguro acá a
propósito: con folio+TRN+documento atómicos en un solo paso (§1.2), un
timeout del caller que reintenta "crear la transacción" crea una
transacción NUEVA de verdad (con su propio folio) — evitar ESE
duplicado es responsabilidad de quien llama (ej. una idempotency key
en la API de alta del documento), no de este spec. No está pedido por
ningún requisito (R1–R7), así que no se construye.

## 3. Motor de asignación

### 3.1 Resolución de perfil

Dado `(header_id, subtipo_transaccion_id, branch_id)` — estos tres
valores salen del registro que se está creando, no se eligen a mano:

1. Buscar un perfil activo con **los tres exactos**: `header_id` +
   `subtipo_transaccion_id` (exacto, `nil` cuenta como valor — sin
   fallback, decisión confirmada) + `branch_id` exacto.
2. Si no hay resultado Y `branch_id` no era `nil`, repetir la búsqueda
   con `branch_id: nil` (perfil global) — mismo `header_id` +
   `subtipo_transaccion_id`, sin fallback en ese último.
3. Si sigue sin haber resultado → `{:error, :perfil_no_encontrado}`.
   Ningún fallback de Subtipo — un subtipo sin perfil configurado
   explícitamente para él es un error, no cae a un perfil genérico.

La restricción de unicidad (§2.1) garantiza que cada búsqueda de las
dos anteriores encuentra 0 o 1 fila, nunca ambigüedad.

### 3.2 Asignación (dentro de la transacción atómica, §1.2)

1. Resolver perfil (§3.1) — lectura normal, todavía sin lock.
2. `SELECT ... FOR UPDATE` sobre esa fila de `folio_perfiles` por
   `id` —ésta es la unidad real de bloqueo (R3): dos perfiles
   distintos nunca contienden entre sí, solo dos pedidos para el
   MISMO perfil serializan acá.
3. `UPDATE folio_perfiles SET numero_actual = GREATEST(numero_actual,
   numero_inicial - 1) + 1 RETURNING numero_actual` — atómico, ya con
   el lock tomado. **Refinamiento encontrado en Tasks** (no un simple
   `+ 1` como decía esta sección originalmente): `numero_actual` nunca
   se "siembra" con `numero_inicial` al crear el perfil (arranca en el
   default físico 0) — el `GREATEST` hace que el PRIMER pedido igual
   respete `numero_inicial`, sin necesitar un paso de sembrado aparte.
   Después del primer folio, `numero_actual` siempre es `>= numero_inicial
   - 1`, así que `GREATEST` deja de cambiar nada (coherente con §2.1:
   `numero_inicial` no se reusa después del primer folio).
4. Generar TRN (reusa `MetadataApp.TRN`, con su propio reintento ante
   colisión — ver riesgo anotado en §1.2).
5. Insertar la fila en `folio_historial` con folio, TRN, `entity_id`
   del registro, y los denormalizados de §2.2.
6. Devolver folio+TRN para que el paso que envuelve todo esto (§1.2)
   los aplique al registro antes de que la transacción confirme.

### 3.3 El registro transaccional guarda su propio Folio (decisión, 2026-09-01)

Confirmado: **dos columnas físicas separadas** en cada catálogo
transaccional que use folio — `folio_serie` (string(4)) y
`folio_numero` (integer) — no un string combinado. Permite ordenar/
filtrar por el número puro sin parsear texto (ej. "traer los folios
100 a 200 de la serie AAAA"). El "Serie-Folio" que ve el usuario final
(R2, Glosario) se arma en la capa de presentación concatenando las dos
columnas, no se guarda una tercera vez.

Mismo criterio que `trn`/`ulid` hoy: nullable a nivel de columna (la
garantía de "todo catálogo con folio configurado SIEMPRE lo tiene" es
de aplicación — corre en cada alta, §1.2 — no de constraint de base),
y ambas quedan fuera de `@campos` del schema generado — ningún PATCH
las toca, el único camino para asignarlas es el motor (§3.2).

## 4. Cambios al generador de catálogos

Para que `folio_serie`/`folio_numero` existan en un catálogo hace
falta tocar el mismo mecanismo que ya generó `trn`/`ulid`:

- **`meta_schema_header`**: nueva columna `requiere_folio` (boolean,
  default `false`) — igual patrón que `schema_es_transaccional`. Un
  catálogo con `requiere_folio: true` es candidato a tener perfiles de
  numeración configurados para él.
- **`MetaCatalogoGenerico`** (macro `__using__/1`): nueva opción
  `folio: true` que agrega `field :folio_serie, :string` +
  `field :folio_numero, :integer` al schema generado — mismo patrón
  que `trn_field_asts/1`.
- **`CatalogoGenerador`**: la migración de creación (catálogo nuevo)
  y el retrofit (`ALTER TABLE`, catálogo ya existente que recién ahora
  activa `requiere_folio`) agregan las dos columnas — mismo patrón que
  `columnas_trn`/`asegurar_trn`.

**Nota de alcance**: `requiere_folio: true` no debería ser posible sin
`schema_es_transaccional: true` (folio siempre viaja con TRN, §1.2) —
validación a nivel de changeset de `Header`, mismo criterio que ya
existe para `codigo_trn`.

**UI para activarlo (agregado 2026-09-02, a pedido explícito)**: hasta
esta fecha `requiere_folio` solo se podía prender por SQL directo o
consola de Elixir (`Header.changeset/2` + `Repo.update`) — sin
checkbox en ningún lado, ni siquiera al crear el catálogo. Se agregó
en el wizard **"Nuevo Completo"**
([bc_nuevo_completo_live.ex](../../../lib/metadata_app_web/live/sysadmin/bc_nuevo_completo_live.ex)),
un checkbox "Folio" (sección "Folio:") inmediatamente debajo del de
"TRN", mismo mecanismo (`contexto["requiere_folio"]`, hidden input +
checkbox, coercionado a boolean en `validar_contexto`, viaja en
`attrs_base["header"]["requiere_folio"]` hasta `Header.changeset/2` —
la validación de la nota de arriba ya lo rechaza si "Es una operación
transaccional" no está tildado, sin código nuevo de validación).
**Sigue pendiente**: un toggle equivalente para un catálogo YA
CREADO (hoy `BcMotorLive` no tiene ningún campo de este spec — ni
`schema_es_transaccional`, ni `codigo_trn`, ni `requiere_folio` —
editable después del alta; activarlo en un catálogo existente sigue
siendo SQL/consola + `CatalogoGenerador.generar/1` a mano).

## 5. Módulo y API pública

**`MetadataApp.IdentificadoresTransaccionales`** reemplaza el punto de
entrada que hoy es `MetadataApp.TRN.asignar_si_transaccional/1` —
único módulo que `crear_simple/3` y `MetaStateEngine.
ejecutar_nucleo_alta/4` llaman (§1.1/§1.2), desde DENTRO de su propia
transacción/`Multi` (no después, como TRN corre hoy).

```elixir
IdentificadoresTransaccionales.asignar(repo, registro, header, contexto \\ %{})
# => {:ok, registro_actualizado} | {:error, motivo}
```

- `repo` — el repo/handle de la transacción en curso (compatible con
  `Multi.run/3`, que ya inyecta esto).
- `registro` — la fila recién insertada DENTRO de la transacción (ya
  tiene `id`, Postgres lo asigna al insertar aunque no haya commit
  todavía).
- `header` — el `meta_schema_header` ya resuelto por el caller (evita
  re-consultarlo).

Internamente, en un solo paso:
1. Si `header.schema_es_transaccional` → genera y asigna TRN/ULID
   (misma lógica de reintento ante colisión que ya tiene `TRN.asignar/3`
   hoy, adaptada para correr dentro de ESTA transacción en vez de abrir
   la suya propia).
2. Si además `header.requiere_folio` → resuelve perfil (§3.1), toma el
   lock e incrementa (§3.2), arma `folio_serie`/`folio_numero`, inserta
   `folio_historial` (ya con el TRN del paso 1 disponible).
3. Si ninguno de los dos aplica → pass-through, `{:ok, registro}` sin
   tocar nada (mismo comportamiento no-op que `TRN.
   asignar_si_transaccional/1` ya tiene hoy para catálogos no
   transaccionales).

`MetadataApp.TRN` no desaparece como módulo — sus funciones de bajo
nivel (generar el string TRN, el ULID) las sigue reusando el módulo
nuevo; lo que se retira es su rol de PUNTO DE ENTRADA desde
`catalogo_generico.ex` (eso pasa a ser
`IdentificadoresTransaccionales`).

## 6. Administración de perfiles (R1)

`folio_perfiles` se administra como **BC real del motor de
catálogos** (Get/Post estándar, permisos, Ficha) — mismo patrón que
ya se armó una vez (y funcionó) antes de descartar ese intento por
otros motivos. Concretamente:

- Un catálogo nuevo (`schema_context_type: 1`) con campos de negocio:
  Tipo de transacción (`referencia` → `meta_schema_header`), Subtipo
  (`referencia` → el futuro catálogo de Subtipos, o `integer` simple
  mientras ese catálogo no exista — ver dependencia asumida en §2),
  Sucursal (`referencia` → `meta_schema_branch`, opcional), Serie
  (`string`, longitud 4), Número inicial (`integer`). `numero_actual`
  NO es un campo de negocio editable — mismo criterio que `estado_id`/
  `trn`: fuera de `@campos`, el único camino para tocarlo es el motor
  (§3.2).
- Sin autómata por ahora — no hay ningún requisito (R1–R7) que pida un
  ciclo de vida Activo/Cancelado para el perfil en sí. Si hace falta
  más adelante, es una extensión, no bloquea esta spec.
- `numero_actual` (el contador) coexiste en la misma tabla generada
  por el motor de catálogos, pero fuera de `@campos` — exactamente el
  mismo mecanismo que ya aísla `estado_id`/`trn`/`ulid`/`folio_*` de
  cualquier catálogo transaccional normal (§3.3): la Ficha de este BC
  nunca lo edita, el único camino para tocarlo es el `SELECT ... FOR
  UPDATE` de §3.2. No es un caso nuevo, es el mismo patrón aplicado
  una vez más.
- Publicado donde el administrador funcional lo encuentre — carpeta a
  definir en `tasks.md` (ej. Sistema → Transacciones, mismo lugar que
  se usó la vez pasada).
