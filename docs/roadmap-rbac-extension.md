# Roadmap — RBAC, extensión para escala (100 roles × 1000 catálogos)

> Este documento es una especificación para implementar más adelante — **nada de esto está construido todavía**, salvo lo que ya existe y se lista en "Estado actual". Nace de una conversación de diseño (2026-07-26) sobre cómo administrar permisos cuando el número de roles y de catálogos crece mucho — comparando contra cómo lo resuelven Salesforce, SharePoint, AWS IAM, SAP y Odoo.

## El problema

RBAC (Fase 1 Auth + Fase 2 completa, ver `docs/roadmap.md` y el historial de commits de 2026-07-25/26) ya funciona de punta a punta: roles, permisos por catálogo, permisos por transición (automático, deny-by-default), y 4 pantallas en `/sysadmin` (Roles y Permisos, Usuarios de la empresa, Empresas, y el detalle de rol con buscador de catálogos).

Todo lo construido hasta ahora es **"vista por rol"**: entrás a un rol y buscás qué catálogos puede tocar. Con pocos roles y pocos catálogos alcanza. El problema aparece a escala — si hay ~100 roles y ~1000 catálogos, y estás configurando **un catálogo puntual** (por ejemplo, acabás de publicar un BC nuevo), hoy no hay forma de ver "¿qué roles ya tienen acceso a este catálogo?" sin entrar rol por rol. Falta la vista inversa, y falta un mecanismo que no obligue a tomar 1000 decisiones una por una.

## Estado actual (para no re-derivar nada en la sesión que retome esto)

- Contexto: `MetadataApp.Permissions` (`lib/metadata_app/permissions.ex`) — `can?/3`, `permisos_de_usuario/2` (cacheado en ETS, `MetadataApp.Permissions.Cache`), `crear_permiso/1`, `crear_rol/1`, `asignar_permiso_a_rol/2`, `conceder_permiso_catalogo/3` (alta + concesión en un paso), `revocar_permiso_de_rol/2`, `reemplazar_permisos_de_rol/2` (reemplazo atómico), `estado_permisos_para_pares/2` (batch, genérico para cualquier lista de `{recurso, accion}`), `buscar_catalogos/2` (ilike + limit 20, nunca carga el universo completo), `transiciones_de_catalogos/1`.
- Tablas: `meta_schema_permiso`, `meta_schema_rol`, `meta_schema_rol_permiso`, `meta_schema_usuario_rol` — todas con GUID de auditoría (`insert_guid` obligatorio, sin timestamps, mismo patrón que `meta_schema_estados`/`meta_schema_transiciones`).
- Pantallas (`lib/metadata_app_web/live/sysadmin/`): `RolesLive` (listar/crear/eliminar roles), `RolDetalleLive` (buscador de catálogos con toggles leer/crear/editar/eliminar + transiciones reales del catálogo, y usuarios asignados al rol), `UsuariosEmpresaLive` (alta/baja de miembros de la empresa activa, unifica "agregar existente" e "invitar nuevo"), `EmpresasLive` (listar/crear/renombrar empresas — crear te dejar como `administrador` ahí automáticamente).
- El chequeo de permisos por transición del motor de estados es **automático y deny-by-default** (`MetaStateEngine.verificar_permiso_transicion/3`) — no opt-in. El rol `administrador` bypasea todo lo que esté REGISTRADO como permiso (no es un wildcard ciego).
- `/api/:tabla` (CRUD genérico) y el acceso a datos de `CatalogoLive` siguen **sin gate de login** — decisión explícita de la Fase 1, todavía vigente.

## Precedentes de la industria (por qué se diseñó así)

| Sistema | Patrón | Qué tomamos de acá |
|---|---|---|
| **Salesforce** (Object Manager) | Entrás a UN objeto y ves una matriz con todos los perfiles/permission sets como filas, CRUD como columnas | Fase A: la pantalla espejo por catálogo |
| **SharePoint / Google Drive** | "Verificar permisos" sobre una carpeta puntual muestra qué grupos tienen acceso a ESA carpeta | Mismo espíritu que Fase A |
| **AWS IAM** | Vista por rol/policy Y vista por recurso (qué principals acceden a este bucket); además, un **explicit Deny** en cualquier policy le gana a cualquier Allow, venga de donde venga | Fase A (vista por recurso) y Fase F (deny explícito) |
| **NTFS / SharePoint (herencia)** | Permisos heredados de la carpeta padre, con la opción puntual de "romper herencia" en un hijo | Fase E |
| **SAP / Odoo** | Filtran la lista de reglas de acceso por objeto/modelo; SAP prefiere autorizaciones estructurales/aditivas, evita el "deny" por lo difícil que hace la auditoría | Contraejemplo a tener en cuenta en Fase F — el deny complica el "por qué no puede hacer esto" |

## Orden recomendado (por costo/riesgo/beneficio, no por lo más vistoso primero)

**A → B → C son baratas y de bajo riesgo — no tocan `can?/3` ni el schema. D es de bajo riesgo pero de valor tardío (recién sirve con volumen real). E y F sí tocan el núcleo del sistema (la función más usada de todo RBAC) y merecen su propia ronda de diseño antes de escribir código, igual que se hizo con cada fork grande de la Fase 2 original.**

### Fase A — Pantalla espejo por catálogo

Nueva ruta `/sysadmin/catalogos/:recurso/permisos` (o similar): fija el catálogo, muestra una tabla de roles (buscable/paginada, mismo criterio de escala que `buscar_catalogos/2`) con toggles de leer/crear/editar/eliminar + transiciones reales de ESE catálogo.

- Reusa `estado_permisos_para_pares/2` invirtiendo qué se fija: en vez de `for recurso <- recursos, accion <- @acciones`, es `for rol <- roles_resultado, accion <- acciones_de_este_catalogo`.
- Necesita una función nueva chica: `Permissions.buscar_roles(empresa_id, query, limite \\ 20)` (mismo patrón ilike+limit que `buscar_catalogos/2` y `buscar_usuarios_de_la_empresa/3`).
- Sin cambios de schema. Sin cambios a `can?/3`. Cero riesgo sobre lo que ya funciona.
- Enlace natural: agregar un link "Ver quién tiene acceso" desde donde sea que se liste/edite un catálogo (BcListLive, BcMotorLive) hacia esta pantalla.

### Fase B — Selección múltiple + aplicar en bloque

Dentro de la pantalla de la Fase A: checkboxes para elegir varios roles + un botón "Conceder leer a los seleccionados" (o la acción que sea). Backend: loop sobre `conceder_permiso_catalogo/3` (ya existe, no hace falta nada nuevo). Depende de que A ya exista — no es una fase de esfuerzo real distinto, es una extensión de la misma pantalla.

### Fase C — Clonar rol

Botón "Duplicar este rol" en `RolesLive`/`RolDetalleLive`. Backend nuevo: `Permissions.clonar_rol(rol_id, nombre_nuevo, empresa_id)` — crea el rol nuevo y copia todas las filas de `rol_permiso` del rol origen (mismos `permiso_id`, nuevo `rol_id`). Sin cambios de schema. Independiente de A/B, se puede hacer en paralelo.

### Fase D — Reporte de auditoría exportable

Vista de solo lectura (no editable): matriz completa rol × catálogo × acción, exportable (CSV o similar), para revisiones de cumplimiento tipo SOC2. No toca enforcement — es una query de lectura sobre lo que ya existe. Baja prioridad hasta que haya volumen real configurado (con 2-3 roles y 3 catálogos, como hoy, no aporta nada todavía).

### Fase E — Herencia por carpeta/módulo

**El cambio real de fondo** — sin esto, 1000 catálogos siempre van a ser 1000 decisiones una por una, sin importar qué tan buena sea la UI. Idea: un permiso concedido a nivel CARPETA (las carpetas ya son filas de `meta_schema_header` con `schema_context_type == 2`, no hay que inventar una entidad nueva) se hereda a todos los catálogos de adentro, salvo que se diga explícitamente lo contrario.

Preguntas de diseño a resolver ANTES de programar (no adivinar, confirmar con el usuario primero — mismo criterio que cada fork grande de la Fase 2 original):

- ¿Un catálogo puede tener un permiso explícito propio que **sume** a lo heredado, o solo puede *ausencia de override* (heredar tal cual)? ¿Hace falta ya en esta fase la posibilidad de "romper herencia" sin llegar a la Fase F (deny), o el override simple alcanza por ahora?
- Un catálogo puede estar anidado en más de un nivel de carpeta (carpeta → subcarpeta → catálogo) — ¿se camina toda la cadena de ancestros, o solo el padre directo?
- Impacto en cache: `cargar_permisos_de_db/2` (adentro de `Permissions`) tiene que resolver la unión (permisos propios del catálogo ∪ heredados de cada carpeta ancestro) al momento de construir la lista cacheada — la forma pública de `permisos_de_usuario/2` no cambia, solo lo que hay adentro.
- Impacto en la UI: la Fase A (pantalla por catálogo) va a necesitar mostrar "heredado de [carpeta X]" vs "explícito en este catálogo", para que no sea confuso de dónde sale un check.

### Fase F — Revoke Set (exclusiones explícitas sobre lo heredado)

Sigue a la Fase E, **no junto con ella** — mismo motivo que separar A/B/C de E: minimizar cuánta complejidad nueva se mete de una sola vez en la función más crítica del sistema. Ideal esperar a que la Fase E esté un tiempo estable en uso real, para que los casos reales de "necesito excluir esto puntual" informen el diseño en vez de adivinarlo hoy.

Patrón: "explicit deny" de AWS IAM — una exclusión explícita le gana a cualquier allow, venga de donde venga (rol propio o heredado). Preguntas a resolver cuando se diseñe en serio:

- ¿El rol `administrador` queda exento de cualquier exclusión (sigue siendo el "rol de emergencia" simple y predecible), o hasta él puede ser excluido? Recomendación de esta conversación: que quede exento.
- ¿Dónde vive el dato? ¿Tabla nueva de exclusiones, o un flag/tipo sobre la estructura de `rol_permiso` que ya existe?
- Con deny explícito, "por qué este rol no puede hacer X" deja de ser obvio (hay que revisar si hay un allow en algún lado Y si hay un deny que le gana) — esto hace que la Fase D (auditoría) valga más la pena si se hace después de F, y probablemente conviene sumar ahí un "explicar por qué" puntual (qué permiso/regla ganó y por qué), no como fase separada.
- SAP evita el deny justamente por esto — vale la pena, al diseñar F en serio, decidir conscientemente si el beneficio (exclusiones puntuales) compensa el costo de auditabilidad, o si un modelo puramente aditivo con "romper herencia" (sin llegar a deny real) alcanza.

## "Prompt" para retomar esto en una sesión futura

Cuando se vaya a implementar, se arranca por la **Fase A** (la más barata, cero riesgo, no depende de nada más de este documento). Este bloque alcanza como punto de partida:

> Implementa la Fase A del roadmap en `docs/roadmap-rbac-extension.md`: una pantalla espejo de `RolDetalleLive` pero centrada en el catálogo en vez de en el rol — nueva ruta (ej. `/sysadmin/catalogos/:recurso/permisos`), gateada por `rbac_admin/leer` igual que las otras 4 pantallas de sysadmin. Necesita una función nueva `Permissions.buscar_roles/3` (mismo patrón ilike+limit que `buscar_catalogos/2`), y reusa `estado_permisos_para_pares/2` invirtiendo qué eje se fija. Revisar primero `lib/metadata_app/permissions.ex` completo y `lib/metadata_app_web/live/sysadmin/rol_detalle_live.ex` como plantilla directa (es casi el mismo patrón con los ejes invertidos). Sin cambios de schema. Verificar con datos reales (curl + servidor real, no solo mocks), igual que el resto de la Fase 2. Las Fases B-F quedan documentadas en este mismo archivo para después — no arrancar con ellas todavía, y en particular las Fases E/F tienen preguntas de diseño sin resolver que hay que confirmar con el usuario antes de escribir código (marcadas explícitamente arriba).
