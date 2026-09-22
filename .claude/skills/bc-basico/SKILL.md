---
name: bc-basico
description: Cómo dar de alta un Business Context (catálogo) siguiendo el patrón básico estándar del proyecto — nombre snake_case con prefijo pty_, autómata Activo/Baja con alta/guardar/baja/reactivar, alcance y permisos de rol, GET/POST Config por default. Usar cuando el usuario pide crear un "BC básico", un catálogo nuevo con el patrón estándar, o dice "dale el patrón de siempre" a un catálogo nuevo.
---

# BC básico — patrón estándar

Checklist para dar de alta un Business Context nuevo con el patrón que
ya usa el resto de los catálogos del proyecto (ver
`pty_aly_marcas`/`pty_clientes` como referencia histórica). Dos
pantallas cubren todo el flujo, en este orden:

1. El wizard **`nuevo-completo`** (`/sysadmin/bc-list/nuevo-completo`,
   `bc_nuevo_completo_live.ex`) — arma catálogo + campos + autómata en
   memoria, nada toca la base hasta el botón final "Crear".
2. El **Motor del catálogo** (`/sysadmin/bc-list/<catalogo>/motor`,
   `bc_motor_live.ex` + `plantilla_constructor_live.ex`) — ya creado,
   ahí se ajustan alcance, permisos y las dos plantillas de
   presentación.

Ejecutá los pasos por navegador (con lo que la sesión tenga disponible
para automatizarlo) o guiá al usuario click a click si no hay acceso
directo — no reinventes el mecanismo a mano vía API salvo que ninguna
de las dos pantallas cubra algo puntual. Los `file:line` de acá abajo
son para verificar rápido, no para confiar de memoria — si algo
cambió, el código manda.

## 0. Antes de arrancar — no asumir

Si el usuario no dio alguno de estos cuatro datos, preguntalo antes de
tocar el wizard — no elegir en silencio ninguno:

| Dato | Si falta, preguntar | Verificar antes de usarlo |
|---|---|---|
| **Nombre del catálogo** | nombre corto, sin prefijo | que no exista ya (`priv/repo/catalogos/<nombre>.meta.json` o `bc-list`) — el wizard arma `pty_<nombre>` solo |
| **Campos de negocio** | campo por campo: nombre + tipo | tipo `referencia` exige que el catálogo destino ya exista |
| **Rol con todos los permisos** | qué rol usar o crear | que no exista ya un rol con ese nombre (único global) — nunca crear `es_sistema: true` por script sin verificar antes |
| **Alcance** | cuál de los seis (explicar en criollo si el usuario no es técnico en esto) | — |

Tipos de campo soportados (`string`, `decimal`, `integer`, `boolean`,
`date`, `enum`, `referencia`): `string` pedí longitud, `decimal` pedí
precisión + escala, `referencia` pedí a qué catálogo apunta. El
sistema arma el nombre real de cada campo solo (`pty_<nombre>_<campo>`)
— no hace falta prefijarlo a mano.

Opciones reales de alcance (`lib/metadata_app/autenticacion/rol_alcance.ex`):
`propio`, `branch` (sucursal), `sales_unit`, `inventory_location`,
`empresa`, `global`.

## 1. Wizard `nuevo-completo`

**a. Contexto** — nombre (sufijo, sin `pty_`), etiqueta, carpeta del
nav, ícono, visible. Si el catálogo es detalle de un maestro
existente, marcalo ahí ("Detalle de") — un BC básico normal no lo es.

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
en `bc-list` antes de seguir al Motor.

## 2. Motor del catálogo — post-creación

Todo lo de acá vive en `/sysadmin/bc-list/<catalogo>/motor`.

**a. Alcance de datos** (pestaña Permisos) — nace en Sucursal por
default (`activar_alcance_con_default_sucursal/1`). Si el alcance
pedido en el paso 0 es otro, ajustalo acá.

**b. Permisos del rol** (misma pestaña, matriz de roles) — botón
**"Conceder todos"** (`conceder_todos` en `catalogo_permisos_live.ex`),
idempotente: da de una sola vez todo el CRUD + las transiciones al rol
del paso 0. No lo armes a mano permiso por permiso.

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
sola vez, se hace nodo por nodo. Guardá y "Publicá" la plantilla.

## 3. Reglas PRE/POST — no tocar

Un BC básico no lleva reglas de negocio propias. El vocabulario
cerrado de reglas built-in (`lib/metadata_app/meta_state_engine/reglas/{pre,post}.ex`)
se compila tal cual:

- PRE: `campos_requeridos`, `campo_cumple`, `sin_relacionados`,
  `requiere_rol`, `requiere_permiso`, `dato_en_contexto`.
- POST: `estampar_valor`, `mutar_relacionados`, `notificar`.

Si más adelante hace falta una regla propia, va como plugin aparte vía
`mix motor.reglas.andamiar` — nunca editando `pre.ex`/`post.ex`.

## 4. Verificar de punta a punta

Antes de dar el BC por terminado: crear un registro real (dispara
`alta`), editarlo (dispara `guardar`), darlo de baja y reactivarlo —
confirmando que el rol del paso 0 puede hacer las cuatro cosas y que
nadie sin ese permiso puede. Si se usaron datos de prueba en la DB de
dev compartida, limpiarlos al terminar (no dejar demo data residual).

## 5. Publicar

Una vez verificado, `mix motor.publicar <catalogo>` — valida el motor,
exporta metadata+autómata a los JSON versionados
(`priv/repo/catalogos/<catalogo>.meta.json`/`.motor.json`) y arma el
commit acotado a ese catálogo. El `git push` queda aparte, a criterio
del usuario.

## Resumen — orden de los 5 pasos

1. Confirmar nombre, campos+tipos, rol y alcance (preguntar lo que
   falte, verificar que nada choque con algo ya existente).
2. Wizard `nuevo-completo`: Contexto → Campos → "Crea BC Base" → Crear.
3. Motor del catálogo: Alcance de datos → Permisos ("Conceder todos")
   → GET Config (toggle "Campos por default") → POST Config (ocultar
   nodos de control uno por uno).
4. No tocar reglas PRE/POST — un BC básico no las necesita.
5. Verificar el ciclo completo (alta/guardar/baja/reactivar) y
   `mix motor.publicar <catalogo>`.
