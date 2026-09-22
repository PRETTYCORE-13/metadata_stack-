---
name: patron-bc
description: Cómo dar de alta un Business Context (catálogo) siguiendo el patrón estándar del proyecto — nombre snake_case con prefijo pty_, autómata Activo/Baja con alta/guardar/baja/reactivar, alcance y permisos de rol, GET/POST Config por default. Incluye la variante maestro-detalle (un catálogo maestro + una o más tablas detalle/renglones colgadas de él, ej. pedido+items): tabla(s) detalle sin autómata propio, "Detalle de" apuntando al maestro, sin TRN ni Serie+Folio por ser esclava, y permisos de insertar/actualizar/borrar renglones por estado. Usar cuando el usuario pide crear un "BC básico"/"patrón BC", un catálogo maestro-detalle, o dice "dale el patrón de siempre" a un catálogo nuevo.
---

# Patrón BC — estándar (básico y maestro-detalle)

Checklist para dar de alta un Business Context nuevo con el patrón que
ya usa el resto de los catálogos del proyecto (ver
`pty_aly_marcas`/`pty_clientes` como referencia histórica de BC básico,
`pty_crm_comando_enc`/`pty_crm_comando_det` como referencia de
maestro-detalle). Dos variantes:

- **BC básico**: un solo catálogo, con su propio autómata Activo/Baja.
- **BC maestro-detalle**: un catálogo maestro (autómata propio, patrón
  de siempre) + una o más tablas detalle/renglones colgadas de él (ej.
  pedido→items) — cada detalle es también un catálogo, pero **nunca
  tiene autómata, TRN, folio ni permisos de rol propios**: todo eso lo
  hereda o lo controla el maestro. Ver §1-bis y §2-bis más abajo, son
  las únicas secciones que cambian respecto al básico.

Dos pantallas cubren todo el flujo, en este orden:

1. El wizard **`nuevo-completo`** (`/sysadmin/bc-list/nuevo-completo`,
   `bc_nuevo_completo_live.ex`) — arma catálogo + campos + autómata en
   memoria, nada toca la base hasta el botón final "Crear". Para
   maestro-detalle se usa una vez por el maestro y una vez MÁS por
   cada tabla detalle (mismo wizard, distinto contexto).
2. El **Motor del catálogo** (`/sysadmin/bc-list/<catalogo>/motor`,
   `bc_motor_live.ex` + `plantilla_constructor_live.ex`) — ya creado,
   ahí se ajustan alcance, permisos y las dos plantillas de
   presentación. Para maestro-detalle, el Motor del MAESTRO es donde
   viven los permisos de insertar/actualizar/borrar renglones (§2-bis)
   — el Motor de cada catálogo detalle es más chico, ver §2-ter.

Ejecutá los pasos por navegador (con lo que la sesión tenga disponible
para automatizarlo) o guiá al usuario click a click si no hay acceso
directo — no reinventes el mecanismo a mano vía API salvo que ninguna
de las dos pantallas cubra algo puntual. Los `file:line` de acá abajo
son para verificar rápido, no para confiar de memoria — si algo
cambió, el código manda. Para el detalle funcional/técnico completo
del mecanismo maestro-detalle (16 requerimientos, 7 fases, todas
implementadas), ver `docs/catalogo-maestro-detalle-requerimientos.md`
— acá solo se documenta el checklist operativo de alta.

## 0. Antes de arrancar — no asumir

Si el usuario no dio alguno de estos datos, preguntalo antes de tocar
el wizard — no elegir en silencio ninguno:

| Dato | Si falta, preguntar | Verificar antes de usarlo |
|---|---|---|
| **Nombre del catálogo** (del maestro, y de cada detalle si aplica) | nombre corto, sin prefijo | que no exista ya (`priv/repo/catalogos/<nombre>.meta.json` o `bc-list`) — el wizard arma `pty_<nombre>` solo |
| **¿Es maestro-detalle?** | si el catálogo va a tener tabla(s) de renglones colgadas (ej. "un pedido con items") | — si sí, listar cuántas tablas detalle y el nombre de cada una |
| **Campos de negocio** (del maestro, y de cada detalle por separado) | campo por campo: nombre + tipo | tipo `referencia` exige que el catálogo destino ya exista |
| **Rol con todos los permisos** | qué rol usar o crear | que no exista ya un rol con ese nombre (único global) — nunca crear `es_sistema: true` por script sin verificar antes |
| **Alcance** | cuál de los seis (explicar en criollo si el usuario no es técnico en esto) | — (solo aplica al maestro/BC básico, un catálogo detalle no tiene alcance propio) |

Tipos de campo soportados (`string`, `decimal`, `integer`, `boolean`,
`date`, `enum`, `referencia`): `string` pedí longitud, `decimal` pedí
precisión + escala, `referencia` pedí a qué catálogo apunta. El
sistema arma el nombre real de cada campo solo (`pty_<nombre>_<campo>`)
— no hace falta prefijarlo a mano.

Opciones reales de alcance (`lib/metadata_app/autenticacion/rol_alcance.ex`):
`propio`, `branch` (sucursal), `sales_unit`, `inventory_location`,
`empresa`, `global`.

**Orden obligatorio para maestro-detalle**: primero se arma el maestro
completo (wizard + "Crea BC Base" + Motor con su autómata), recién
después cada tabla detalle — el wizard de un detalle necesita elegir
el maestro en un `<select>` de catálogos YA existentes (`Detalle de`),
no se puede crear al revés.

## 1. Wizard `nuevo-completo` — catálogo maestro (o BC básico sin detalle)

**a. Contexto** — nombre (sufijo, sin `pty_`), etiqueta, carpeta del
nav, ícono, visible. Dejá **"Detalle de"** en `— No es detalle de
nada —` (es el catálogo maestro o un BC básico independiente). Si el
catálogo va a ser transaccional (Venta, Factura, Cobro) tildá "Es una
operación transaccional (TRN)" y, si además necesita numeración
correlativa, "Necesita Serie + Folio" (exige TRN tildado antes).

**b. Campos** — cargá cada campo de negocio del paso 0 con su tipo y
configuración (longitud / precisión+escala). No agregues ningún campo
de sistema a mano (`id`, `estado_id`, los GUID) — el motor los agrega
solo.

**c. Botón "Crea BC Base"** — en vez de armar Estados/Transiciones a
mano, usalo (`handle_event("crear_bc_base", ...)`). Arma automáticamente,
en memoria, exactamente el patrón que pide un BC básico:

- Estados: `Activo` (inicial), `Baja`.
- Transiciones: `alta` → Activo, `guardar` (self-loop Activo→Activo,
  editable), `baja` (Activo→Baja), `reactivar` (Baja→Activo).

No lo reconstruyas manualmente estado por estado. Antes de confirmar,
**verificá en pantalla** que la transición `guardar` quedó con todos
los campos de negocio tildados como editables — si el wizard no los
tilda solos, agregalos ahí mismo.

**d. "Crear"** — recién ahí se persiste de verdad (tabla, migración,
schema Ecto, metadata). Confirmá que compiló y que el catálogo aparece
en `bc-list` antes de seguir al Motor (o, si hay tablas detalle
pendientes, antes de seguir a §1-bis).

## 1-bis. Wizard `nuevo-completo` — cada tabla detalle (solo maestro-detalle)

Repetí el wizard una vez POR CADA tabla detalle, con estas diferencias
respecto al maestro (`bc_nuevo_completo_live.ex:1005-1012` para el
selector, `header.ex` R11/R12 de `catalogo-maestro-detalle-requerimientos.md`
para el motivo):

**a. Contexto**:
- **"Detalle de"** — elegí el catálogo maestro ya creado en el
  `<select>` (nunca lo tipees a mano). Esto es lo que setea
  `schema_encabezado_id` — el dato que el tab Configuración del Motor
  va a mostrarte después como "Este catálogo es detalle de
  `<maestro>`" (ver §2-ter). En cuanto elegís un maestro acá, el
  wizard deja de pedirte armar Estados/Transiciones — un catálogo
  detalle nunca tiene autómata propio, comparte el del maestro.
- **"Es una operación transaccional (TRN)"** — dejala **sin tildar**.
  Una tabla detalle nunca lleva TRN/ULID propio por ser esclava — su
  trazabilidad transaccional es la del maestro, vía
  `schema_encabezado_id` (R11).
- **"Necesita Serie + Folio"** — dejala **sin tildar** también (y de
  hecho el sistema ya la bloquea si TRN no está tildado arriba) — por
  el mismo motivo, una esclava no numera folio propio.

**b. Campos** — agregá acá SOLO los campos de negocio propios del
renglón (ej. producto, cantidad, precio) — no repitas ningún campo del
encabezado, el detalle es una tabla aparte con sus propios metacampos.

**c. Estados/Transiciones** — **no aplica, no lo busques**: con
"Detalle de" seteado en el paso a, el wizard ya no muestra el bloque
de autómata — una tabla detalle no lleva estados propios, ni falta
"Crea BC Base" acá.

**d. "Crear"** — persiste el catálogo detalle. Repetí desde a. por
cada tabla detalle adicional que el maestro necesite.

## 2. Motor del catálogo — post-creación

Todo lo de acá vive en `/sysadmin/bc-list/<catalogo>/motor`. Para
maestro-detalle, esta sección (2) es la del **MAESTRO** — un catálogo
detalle tiene un Motor más chico, ver §2-ter.

**a. Alcance de datos** (pestaña Permisos) — nace en Sucursal por
default (`activar_alcance_con_default_sucursal/1`). Si el alcance
pedido en el paso 0 es otro, ajustalo acá.

**b. Permisos del rol** (misma pestaña, matriz de roles) — botón
**"Conceder todos"** (`conceder_todos` en `catalogo_permisos_live.ex`),
idempotente: da de una sola vez todo el CRUD + las transiciones al rol
del paso 0. No lo armes a mano permiso por permiso. Un catálogo
detalle NO tiene esta pestaña ni necesita su propio "Conceder
todos" — sus renglones se manejan con los permisos del maestro, ver
§2-bis.

**c. GET Config** — dejala tal cual la arma el sistema por default
(columnas de negocio + sistema, checkbox de visibilidad, reordenable)
sin personalizar el orden. El toggle **"Campos por default"** vive acá
(`bc_motor_live.ex:2839-2867`): activado trae todos los registros
apenas se abre la tabla, desactivado espera que el usuario busque o
filtre. Para un BC básico (catálogo chico) dejalo **activado**, salvo
que el usuario avise que va a tener muchísimas filas.

**d. POST Config** — es en realidad el Constructor visual de la Ficha
360° (`PlantillaConstructorLive`), no un formulario de API. La
plantilla automática (`regenerar_automatica`) arma un nodo por cada
campo, apilado: los de negocio Y los de control/sistema (`@campos_control`:
empresa, sucursal, almacén, unidad de venta, estado, folio, creado
por, ID), todos visibles por default. Para un BC básico, entrá a cada
nodo de campo de **control** que no haga falta mostrarle al usuario
final y apagale el toggle **"Visible"** en su panel de propiedades
(`panel_propiedades/1`, ~línea 1296) — dejando visibles solo los nodos
de negocio. No hay un botón que oculte todos los de sistema de una
sola vez, se hace nodo por nodo. Guardá y "Publicá" la plantilla. Si
el maestro tiene tabla(s) detalle, la Ficha 360° arma además un tab
"Detalle" con el Grid Editable (renglones tipo Excel) automáticamente
— no hace falta armarlo en POST Config.

## 2-bis. Permisos de insertar/actualizar/borrar renglones (solo maestro-detalle)

Con el autómata del maestro ya armado (Estados + Transiciones, igual
que en un BC básico), el tab Configuración del Motor del MAESTRO
muestra una sección nueva **"Permisos de detalle"** justo debajo de la
tabla de Transiciones (`bc_motor_live.ex:2129`,
`tabla_permisos_detalle/1` ~línea 3044) — solo aparece si el catálogo
tiene al menos una tabla detalle. Es una matriz **Estado × catálogo
detalle**, con 3 toggles de click directo por celda: **Insertar /
Actualizar / Borrar**.

- **Deny-by-default**: si no tildás nada, por default NO se puede
  insertar, actualizar ni borrar (soft-delete real no existe en un
  detalle, "borrar" acá es la transición que lo manda a un estado tipo
  "Cancelado" — R12, nunca un DELETE físico) ningún renglón de esa
  tabla detalle mientras el maestro esté en ese estado — pasalo por
  todos los estados donde el usuario necesite operar renglones (ej.
  tildar los 3 en "Borrador", apagarlos todos en "Cerrado").
- **Mecanismo independiente del permiso RBAC de la transición** — esto
  NO reemplaza el "Conceder todos" del paso 2.b. Son dos preguntas
  distintas: el RBAC de la transición responde "¿este ROL puede
  ejecutar esta transición?"; esta matriz responde "¿en este ESTADO,
  se puede tocar un renglón de esta tabla?" (sin importar el rol). Las
  dos tienen que estar en verde para que un insert/update/"borrado"
  de renglón funcione de verdad.
- **No confundir con el chequeo RBAC por-transición-por-detalle** que
  aparece DENTRO del modal de editar una transición (✓ verde / ⚠ ámbar
  con botón "Registrar permiso", uno por catálogo detalle involucrado)
  — ese solo asegura que la fila `{recurso, accion}` exista en
  `meta_schema_permiso` para poder otorgarla después desde Roles, no
  toca esta matriz de Insertar/Actualizar/Borrar.

## 2-ter. Motor de cada catálogo detalle — mucho más chico

El Motor de un catálogo detalle (`/sysadmin/bc-list/<detalle>/motor`)
solo tiene los tabs **Configuración, Reglas, Relaciones, Get Config,
Post Config** (`bc_motor_live.ex:2054-2072`) — sin Estados,
Transiciones, Diagrama, Contrato ni Permisos, porque ninguno de esos
le aplica (comparte autómata y permisos con el maestro). Al entrar,
el tab Configuración muestra arriba de todo un aviso fijo — "Este
catálogo es detalle de `<maestro>` — comparte su autómata..." con link
de vuelta al Motor del maestro — en vez de las secciones Estados y
Transiciones. Para agregar/editar/eliminar campos del detalle, usá
esta pantalla igual que harías con cualquier catálogo (§ Campos del
patrón normal) — eso no cambia.

## 3. Reglas PRE/POST — no tocar

Un BC básico no lleva reglas de negocio propias. El vocabulario
cerrado de reglas built-in (`lib/metadata_app/meta_state_engine/reglas/{pre,post}.ex`)
se compila tal cual:

- PRE: `campos_requeridos`, `campo_cumple`, `sin_relacionados`,
  `requiere_rol`, `requiere_permiso`, `dato_en_contexto`.
- POST: `estampar_valor`, `mutar_relacionados`, `notificar`.

Si más adelante hace falta una regla propia, va como plugin aparte vía
`mix motor.reglas.andamiar` — nunca editando `pre.ex`/`post.ex`. En
maestro-detalle, cada catálogo detalle tiene su PROPIO namespace de
reglas (`MetadataApp.MetaBusinessProcess.Reglas.<CatalogoDetalle>.*`,
editable desde su propia pestaña "Reglas") — corren por renglón,
dentro del mismo ciclo de la transición del maestro, sin que el header
comparta ni vea la lista de reglas de sus detalles.

## 4. Verificar de punta a punta

Antes de dar el BC por terminado: crear un registro real (dispara
`alta`), editarlo (dispara `guardar`), darlo de baja y reactivarlo —
confirmando que el rol del paso 0 puede hacer las cuatro cosas y que
nadie sin ese permiso puede. Si se usaron datos de prueba en la DB de
dev compartida, limpiarlos al terminar (no dejar demo data residual).

Para maestro-detalle, sumá además: crear el maestro CON renglones
iniciales en la misma alta (o agregarlos después), editar un renglón
existente (dispara la transición `guardar` del maestro, si tiene los
campos del detalle tildados en `campos_editables`), y "quitar" un
renglón vía una transición real (nunca hay DELETE sobre un catálogo
detalle — confirmá que un intento de `DELETE` directo por API lo
rechaza, R12). Repetí la prueba con la matriz de §2-bis en distintas
combinaciones (ej. denegar `permite_insertar` en el estado actual y
confirmar que el insert se rechaza, revertir) para confirmar que el
deny-by-default funciona de verdad y no solo en el caso feliz.

## 5. Publicar

Una vez verificado, `mix motor.publicar <catalogo>` — valida el motor,
exporta metadata+autómata a los JSON versionados
(`priv/repo/catalogos/<catalogo>.meta.json`/`.motor.json`) y arma el
commit acotado a ese catálogo. El `git push` queda aparte, a criterio
del usuario. Para maestro-detalle, publicá el MAESTRO primero y
después cada catálogo detalle por separado (`mix motor.publicar
<detalle>`) — cada uno exporta a su propio archivo, y el detalle
depende de que el `schema_encabezado_id` del maestro ya esté resuelto.

## Resumen — orden de los pasos

1. Confirmar nombre(s), campos+tipos (maestro y cada detalle si
   aplica), rol y alcance (preguntar lo que falte, verificar que nada
   choque con algo ya existente).
2. Wizard `nuevo-completo` del MAESTRO: Contexto (sin "Detalle de") →
   Campos → "Crea BC Base" → Crear.
3. Si es maestro-detalle: wizard `nuevo-completo` de CADA tabla
   detalle — Contexto ("Detalle de" = maestro, TRN y Folio sin
   tildar, sin bloque de autómata) → Campos propios del renglón →
   Crear.
4. Motor del MAESTRO: Alcance de datos → Permisos ("Conceder todos")
   → GET Config (toggle "Campos por default") → POST Config (ocultar
   nodos de control uno por uno) → si es maestro-detalle, "Permisos de
   detalle" (Insertar/Actualizar/Borrar por Estado × catálogo detalle).
5. No tocar reglas PRE/POST del maestro ni de los detalles — un BC
   básico no las necesita (si hace falta una regla propia, va como
   plugin aparte, nunca a mano en `pre.ex`/`post.ex`).
6. Verificar el ciclo completo (alta/guardar/baja/reactivar, y en
   maestro-detalle también insertar/editar/"quitar" renglones con la
   matriz de permisos) y `mix motor.publicar <catalogo>` (maestro
   primero, después cada detalle).
