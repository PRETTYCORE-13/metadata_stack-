# SPEC-SYS-1809202603 — Propagación de Extensiones (CORE)

**Documento:** Design · **Fase:** ✅ aprobada (2026-09-18).

Extiende el mecanismo de `SPEC-SYS-0309202601-alta-sistema-nuevo`
(`MetadataApp.MotorAlta`, `.github/workflows/actualizar-sistema.yml`) —
nada de esto reconstruye una imagen nueva, todo mueve un artefacto ya
construido de un lado a otro.

## 1. Renombrado (R1-R3)

`Mix.Tasks.Motor.Promover` → `Mix.Tasks.Motor.PropagarExtension`
(archivo `lib/mix/tasks/motor.propagar_extension.ex`, uso: `mix
motor.propagar_extension <ambiente> <origen> <destino>`).

`Mix.Tasks.Motor.Actualizar` → `Mix.Tasks.Motor.PropagarExtensionASistema`
(archivo `lib/mix/tasks/motor.propagar_extension_a_sistema.ex`, uso:
`mix motor.propagar_extension_a_sistema <sistema> <imagen>`).

Mismo cuerpo, solo nombre de módulo/archivo/`@shortdoc`/mensajes de
`Mix.shell().info` que mencionan el comando viejo. `MotorAlta` no
cambia — ya era compartido, sigue siéndolo.

Referencias a actualizar (R3): `SPEC-SYS-0309202601/requirements.md`
R10, su `design.md` §3, y el comentario de
`AmbientesLive`/`meta_publicador.ex` si mencionan el nombre viejo
(confirmar con grep al ejecutar `tasks.md`, no listar acá para no
duplicar una búsqueda que puede quedar desactualizada entre el diseño
y la implementación).

## 2. `mix motor.estado_extension` (R4-R5)

Nuevo módulo `MetadataApp.MotorAlta.Estado` (mismo namespace que
`MotorAlta`, separado en archivo propio porque agrega una
responsabilidad nueva — consultar N destinos en paralelo — que no
comparte código con el resto de `motor_alta.ex`).

```
def consultar_todo() ::
  [%{destino: String.t(), tipo: :canal | :sistema, resultado: {:ok, imagen} | {:error, mensaje}}]
```

- Destinos = `MotorAlta.canales/0` (3) + `Map.keys(MotorAlta.leer_sistemas())`
  (N clientes) — mismas dos fuentes que ya existen, ninguna nueva.
- Cada destino se consulta con `MotorAlta.imagen_actual/2` (SSH, ya
  existe) — **en paralelo** (`Task.async_stream/3`, timeout individual
  igual al que ya usa `MetadataApp.Ssh.ejecutar/2` internamente) para
  que N sistemas no multipliquen el tiempo total de espera de forma
  lineal.
- R5 (aislar errores): `Task.async_stream/3` con `on_timeout: :kill_task`
  y capturando `{:error, _}` por tarea — un `{:error, mensaje}` para un
  destino puntual se guarda en su propio resultado, nunca aborta el
  `Enum` completo (a diferencia de `Task.await_many/2`, que sí propaga
  el primer error/timeout a toda la lista).
- El tag de imagen ya ES el hash de commit completo (`ci.yml` tagea
  `:${{ github.sha }}` en cada build, confirmado en el código de CI
  existente) — R4 no necesita mapear nada, el string que devuelve
  `imagen_actual/2` (después de `ghcr.io/.../metadata_stack:` como
  prefijo fijo) ya es directamente comparable/pegable en
  `git show <hash>` o la URL de un commit de GitHub.

`Mix.Tasks.Motor.EstadoExtension` toma `<ambiente>` como argumento
explícito (`mix motor.estado_extension <ambiente>`, confirmado con el
usuario) — mismo criterio que `mix motor.propagar_extension`: nunca
infiere silenciosamente qué servidor SSH usar, aunque hoy en la
práctica solo exista un ambiente relevante (todos los canales y
`ennova` viven en el mismo clúster). `consultar_todo/1` recibe ese
`%Ambiente{}` ya resuelto (`Ambientes.obtener_ambiente_por_nombre/1`,
mismo patrón que ya usa `promover/3` en el task actual) y lo usa para
las N consultas en paralelo.

`Mix.Tasks.Motor.EstadoExtension` (`lib/mix/tasks/motor.estado_extension.ex`)
solo formatea la lista de `consultar_todo/1` en una tabla de texto
(`Mix.shell().info`) — canales primero, después sistemas, orden
alfabético dentro de cada grupo; una fila en rojo/con `[ERROR: ...]`
para los que fallaron, sin frenar el resto del listado.

## 3. Guarda de idempotencia (R6-R7)

**Corregido tras verificar el código real (el supuesto original de esta
sección era incorrecto)**: `mix motor.publicar`/`AmbientesLive` NO
resuelven ningún `%Ambiente{}` por sistema — el despliegue real
(`actualizar-sistema.yml`, `bc-deploy.yml`) usa 3 secrets FIJOS de
GitHub Actions (`DEPLOY_HOST`/`DEPLOY_USER`/`DEPLOY_SSH_KEY`), sin
pasar nunca por la tabla `Ambientes`. Y `mix motor.propagar_extension_a_sistema`
(hoy, post Grupo A) no recibe ningún `<ambiente>` — solo `<sistema>
<imagen>`. La guarda necesita SSH real para consultar el destino antes
de disparar (R7), y la única fuente de credenciales que ya existe es
`Ambientes` (misma tabla que ya usa `mix motor.propagar_extension`).

**Decisión (confirmada con el usuario)**: `mix motor.propagar_extension_a_sistema`
gana un `<ambiente>` explícito, igual que su hermano —
`mix motor.propagar_extension_a_sistema <ambiente> <sistema> <imagen>`
— mismo criterio "nunca infiere" de toda la familia. Cambia la firma
de ese comando (agrega un argumento obligatorio) — justificado porque
es la única fuente real de credenciales disponible, y sin esto la
guarda no puede evaluarse para el camino más sensible (clientes
reales).

**Dónde vive**: NO en `actualizar-sistema.yml` (el workflow de GitHub
Actions) — vive del lado de Elixir, en `MotorAlta.disparar_actualizacion/3`
(gana `ambiente` como primer argumento), ANTES de llamar a
`gh workflow run`. Motivo: el workflow no tiene forma barata de
consultar "qué corre ahí ahora" sin agregarle el mismo SSH que Elixir
ya tiene armado (`MetadataApp.Ssh`) — hacerlo del lado de Elixir reusa
`imagen_actual/2` tal cual, cero código nuevo en YAML, y el guard corre
ANTES de gastar un run de GitHub Actions (más rápido para el operador
— no espera un workflow completo para enterarse de que era un no-op).

```elixir
def disparar_actualizacion(ambiente, sistema, imagen) do
  case imagen_actual(ambiente, sistema) do
    {:ok, ^imagen} ->
      {:ok, :sin_cambios, "\"#{sistema}\" ya está en #{imagen} -- no se disparó ningún workflow."}

    _otro_o_error ->
      # comportamiento actual sin cambios: dispara gh workflow run
  end
end
```

- Ya no hace falta resolver el `%Ambiente{}` por nombre de sistema —
  ambos comandos (`propagar_extension`/`propagar_extension_a_sistema`)
  reciben `<ambiente>` explícito ahora, y `disparar_actualizacion/3` lo
  usa tal cual contra `imagen_actual/2`, mismo mecanismo sin cambios.
- Si la consulta de "imagen actual" falla (SSH caído, etc.), R7 dice
  "nunca contra un valor cacheado" — la guarda simplemente no puede
  evaluarse: se trata igual que "no está actualizado" (`_otro_o_error`
  cubre `{:error, _}` también) y se sigue con el disparo normal, nunca
  se bloquea una actualización real por no poder confirmar un no-op.
  Preferible sobre bloquear: un falso negativo (dispara cuando no
  hacía falta) es solo un `rollout restart` de más; un falso positivo
  (NO dispara cuando sí hacía falta, por un error de lectura) dejaría
  a un sistema desactualizado sin que nadie se entere.
- `Mix.Tasks.Motor.PropagarExtension`/`PropagarExtensionASistema`
  imprimen el mensaje de "sin cambios" tal cual y terminan con
  status 0 (no es un error, es el resultado correcto).

## 4. `--commit=<hash>` (R8)

`Mix.Tasks.Motor.PropagarExtension` acepta un flag opcional:

```
mix motor.propagar_extension <ambiente> <origen> <destino> --commit=<hash>
```

Con el flag: en vez de `MotorAlta.imagen_actual(ambiente, origen)`,
arma la imagen directo como `<prefijo-registro>:<hash>` (mismo prefijo
que ya usan las imágenes de `imagen_actual/2` — `ghcr.io/.../metadata_stack`,
constante ya usada en `manifiestos_k3s/2`, se extrae a un
`@registro_imagen` compartido si hace falta) y valida contra el
registro con `gh api` (mismo patrón `System.cmd("gh", [...])` que ya
usa todo `MotorAlta`) antes de aplicar nada:

**Confirmado real (2026-09-18) contra el registro de verdad**:
`prettycore-13` es un USUARIO de GitHub, no una organización (el
endpoint `/orgs/...` da 404) — y el token de `gh` de este entorno no
tenía el scope `read:packages` por default (403 hasta que el usuario
corrió `gh auth refresh -h github.com -s read:packages`, paso manual,
interactivo, fuera de lo que este código puede hacer solo).

```
gh api users/prettycore-13/packages/container/metadata_stack/versions --paginate --jq '.[].metadata.container.tags[]'
```

(SIN slash inicial en el endpoint -- con `/orgs/...` a secas, Git Bash
en Windows reinterpreta el string como un path de filesystem y `gh`
falla con "invalid API endpoint", encontrado real probándolo). La
lista incluye tags de commit real (40 hex) mezclados con `latest` y
tags `bc-*` (bundles de catálogos de negocio, de otro mecanismo,
`MetaPublicador`) — el filtro de "existe este hash" compara contra
esta lista completa sin intentar distinguir el tipo de tag, un commit
real de 40 hex nunca va a colisionar con esos otros formatos.

Si el hash no aparece: `Mix.raise` con el mensaje claro de "no existe
ninguna imagen con ese commit" — nunca dispara `gh workflow run` con
un tag inventado que GitHub Actions fallaría a mitad de camino, con
menos contexto que un error temprano y claro acá.

Sin el flag: comportamiento actual exacto, sin cambios (toma
`imagen_actual(ambiente, origen)`).

`mix motor.propagar_extension_a_sistema` no cambia — ya toma `<imagen>`
explícita siempre (R2, sin flag nuevo).

## 5. Pantalla `/sysadmin/propagacion` (R9-R9b)

Nuevo LiveView `MetadataAppWeb.Sysadmin.PropagacionLive`
(`lib/metadata_app_web/live/sysadmin/propagacion_live.ex`), mismo
patrón que `AmbientesLive`/`endpoints_live.ex` (`:live_view_admin`,
`on_mount {..., :mount_current_scope}`, gate
`{"sysadmin_propagacion", "leer"}` vía `Hooks.Autorizacion`, agregado
al `@menu` compartido de esas pantallas con
`nav: "/sysadmin/propagacion"`).

**Selector de ambiente (confirmado con el usuario)**: a diferencia del
CLI (que recibe `<ambiente>` como argumento explícito, R6-R8), la
pantalla no tiene un argumento natural — y hoy ya hay más de un
`Ambiente` registrado (`Metadata`, el real para canales/`sistemas.json`;
`crm`, de otra app, sin relación). Un `<select>` simple arriba de la
tabla (`Ambientes.listar_ambientes/0`, mismo dato que ya lista
`AmbientesLive`) — con exactamente 1 ambiente registrado se
preselecciona solo; con 2+, el admin elige; con 0, la tabla muestra un
aviso en vez de intentar consultar nada. `linea_de_tiempo/2` (no `/1`
como decía la versión anterior de esta sección) recibe el `%Ambiente{}`
ya elegido.

**Permiso nuevo**: `sysadmin_propagacion` — mismo criterio que
`sysadmin_ambientes`/`sysadmin_credenciales` (R13a de
`SPEC-SYS-0909202601`: solo aparece en el menú si
`usuario.super_admin == true`, seed de permiso vía migración igual que
`20260816022113_seed_permiso_capacidad_sysadmin_ambientes.exs`).

### 5.1 Fuente de datos (R9a) — `PropagacionContext`

Módulo nuevo `MetadataApp.PropagacionContext` (Elixir puro, sin
LiveView) — el LiveView solo llama a esto y renderiza, ninguna consulta
vive inline en el `.ex` del LiveView (mismo criterio que cualquier
`*_live.ex` de este proyecto delega a su Context):

```elixir
def linea_de_tiempo(ambiente, limite \\ 30) :: [%{
  hash: String.t(), hash_corto: String.t(), mensaje: String.t(),
  autor: String.t(), fecha: DateTime.t(),
  posiciones: [String.t()]  # nombres de canal/sistema parados en ESTE commit
}]
```

- Commits: `git log origin/main --format=... -n <limite>` (mismo
  `System.cmd("git", [...])` que ya usa `MotorAlta.comitear_y_pushear/2`
  — `--format` con un separador no ambiguo, ej. `%H%x1f%h%x1f%s%x1f%an%x1f%aI`,
  parseado a mano, `String.split(línea, "\x1f")`; evita pelear con JSON
  de `git log` que no es nativo).
- Posiciones: reusa `MotorAlta.Estado.consultar_todo/2` (§2) — para
  cada resultado `{:ok, imagen}`, extrae el hash del tag y lo empareja
  contra la lista de commits por igualdad de string exacta. Un destino
  en un hash que NO aparece en los últimos `<limite>` commits
  (`git log` truncado) queda simplemente sin marcar en ninguna fila
  visible — no es un bug, es "muy atrás", el límite es ajustable si
  hace falta verlo (mismo criterio que cualquier paginado).
- Runs de GitHub Actions (R9b, actor + duración + estado):
  `gh run list --workflow=actualizar-sistema.yml --json
  headSha,status,conclusion,actor,createdAt,updatedAt,displayTitle`
  (mismo patrón `--json` + `Jason.decode!` que `meta_tepache.ex:211`,
  `siguiente_tag/0`) — emparejado por `headSha` contra cada commit de
  la línea de tiempo. Un commit sin ningún run calzado (propagado antes
  de que existiera esta spec, o nunca propagado) muestra la fila sin
  esa columna, no es un error.
- **R9b — dos identidades separadas, nunca fusionadas**: `autor` sale
  de `git log` (`%an`, quien escribió el commit); `actor` sale de
  `gh run list` (`.actor.login`, quien disparó ESE run puntual) — la
  UI muestra ambos campos lado a lado en la fila del run, nunca un solo
  campo "quién lo hizo" que mezcle los dos.
- **Nada de esto se guarda en una tabla propia** (R9a) — cada carga de
  la pantalla vuelve a consultar las 3 fuentes en vivo (git, k3s vía
  `Estado.consultar_todo/0`, GitHub Actions) — mismo principio ya
  aprobado en R8/§3 de `SPEC-SYS-0309202601`.

### 5.2 UI (según el mockup de GitHub Actions que el usuario compartió)

- Lista vertical de commits (más reciente arriba), cada fila: ícono de
  estado del run más reciente que aplica a ESE commit (✓ verde /✗ rojo/
  ○ gris si nunca se propagó), mensaje del commit (primera línea),
  hash corto, autor, "run por `<actor>`" cuando hay un run, cuándo
  (tiempo relativo), duración si el run ya terminó.
- Al lado de cada canal/sistema que esté parado en ese commit: un chip
  con su nombre (`unstable`/`testing`/`stable`/`<cliente>`) — permite
  ver, mirando la columna completa, en qué commit está parado cada uno
  sin tener que cruzar manualmente contra `motor.estado_extension`.
  Varios chips pueden caer en la misma fila (varios destinos en el
  mismo commit) o ninguno (commit sin nadie parado ahí todavía).
- Click en un commit sin uno de los chips ya puestos ahí → abre un
  panel/modal para elegir a qué canal o sistema propagar ESE commit
  (dispara R8 — `--commit=<hash>` — del lado servidor, mismo
  `MotorAlta`/`Estado`, ningún camino nuevo de despliegue).
- Refresh: botón manual (mismo criterio que `AmbientesLive` para
  "Detectar automáticamente" — sin polling automático que generaría
  llamadas a `gh`/SSH sin que el admin las pidiera).

**Regla "nunca saltar Testing" también acá (confirmado con el usuario,
Grupo F)** — el picker de destino de un commit NO ofrece cualquier
canal/cliente libremente, mismo criterio que `@pares_validos` del CLI,
reinterpretado para un commit puntual (sin "origen" explícito en la UI):

- `testing` solo aparece como destino ofrecible si `"unstable"` ya está
  en `commit.posiciones` — no se puede promover a testing algo que
  `unstable` mismo no tiene ahora mismo.
- `stable` solo aparece como destino ofrecible si `"testing"` ya está en
  `commit.posiciones` — nunca un salto directo `unstable → stable`.
- Cada cliente (`priv/sistemas.json`) solo aparece como destino
  ofrecible si `"stable"` ya está en `commit.posiciones` — mismo gate
  que ya impone `actualizar-sistema.yml` del lado servidor (R6/R8 de
  `SPEC-SYS-0309202601`); ofrecerlo antes evita un disparo que el
  workflow rechazaría igual, con menos contexto.

Si un commit no tiene NINGÚN destino ofrecible (ej. todavía no llegó a
ningún canal), el picker se muestra vacío con una nota explicando por
qué — nunca se oculta la fila entera.

## 6. Rollback (R10-R10b)

### 6.1 Rollback de código (R10)

Botón "Volver a la versión anterior" en cada chip de canal/sistema de
§5.2 — resuelve el commit inmediatamente ANTERIOR al actual dentro de
`linea_de_tiempo/2` (mismo orden de `git log`, el siguiente elemento de
la lista) y dispara exactamente el mismo camino que R8
(`--commit=<hash>` contra `propagar_extension`/`propagar_extension_a_sistema`,
según si el destino es canal o cliente) — mismo filtro de §5.2 aplica
acá también (consistencia): el botón de rollback de un chip queda
deshabilitado si el commit anterior no cumple la regla de predecesor
para ESE destino (ej. rollback de `stable` deshabilitado si el commit
anterior no tiene `"testing"` en sus posiciones) — **cero código nuevo de
despliegue**, es una UI conveniente sobre un mecanismo que ya existe
desde §4.

### 6.2 Detector de rollback de base de datos (R10a)

**Hallazgo clave que fija el diseño**: al revisar `priv/repo/migrations/`
(366 archivos), la enorme mayoría usa `def change do ... end` (DSL
declarativo, reversible automático de Ecto) — muy pocas usan `def
up`/`def down` explícitos. Un detector que solo mirara "¿tiene `def
down`?" fallaría para casi todo el histórico real. El detector tiene
que **parsear el AST de `change/0`**, no buscar texto ni ejecutar la
migración.

Nuevo módulo `MetadataApp.PropagacionContext.SeguridadMigracion`:

```elixir
def clasificar(ruta_archivo_migracion) ::
  {:automatico, [operacion]} | {:manual, motivo :: String.t(), operacion_bloqueante}
```

Mecanismo:
1. `File.read!(ruta) |> Code.string_to_quoted!()` — parsea el archivo
   a AST (ya usado en el proyecto para otros fines de análisis
   estático de código Elixir generado — mismo enfoque, no una técnica
   nueva en este codebase).
2. Recorre el `quote do ... end` de `def change` con
   `Macro.prewalk/2`, extrayendo cada llamada de top-level dentro de
   `create table(...) do ... end` / `alter table(...) do ... end` /
   llamadas sueltas (`create index(...)`, `create unique_index(...)`,
   `execute(...)`).
3. Clasifica cada operación encontrada:
   - `create table(...)` → candidata a automática — **pendiente
     verificar en vivo** que la tabla resultante tiene 0 filas (paso 4).
   - `add :campo, :tipo` (dentro de un `alter table` sobre tabla
     EXISTENTE) → candidata a automática — **pendiente verificar en
     vivo** que ninguna fila tiene un valor real ahí (NULL o default
     exacto — comparado contra el `default:` que el propio `add/3` ya
     trae en sus opciones, sin tener que adivinarlo).
   - `create index(...)` / `create unique_index(...)` sin `add`
     acompañante en la misma migración → automática siempre (nunca
     toca datos existentes, solo estructura).
   - `remove`, `drop table`, `modify` (cambio de tipo/rename), o
     cualquier `execute/1` → **manual, siempre**, motivo = el texto
     literal de esa operación (para mostrarlo tal cual en R10b, no una
     paráfrasis).
   - Cualquier construcción NO reconocida por el parser (algo fuera de
     esta lista) → **manual por default** — nunca asumir "seguro" ante
     algo que el detector no entiende; el modo seguro es el default
     cuando hay ambigüedad.
4. Para las candidatas de `create table`/`add` (paso 3), una consulta
   real contra el destino confirma vacío/sin-dato-real ANTES de
   confirmarla como automática — si la tabla ya tiene filas, o alguna
   fila difiere del default, esa operación puntual pasa a manual
   igual, con el motivo "hay N fila(s) con datos reales" (alimenta
   directo el "cuántas filas" de R10b). **Corregido al implementar**:
   NO hace falta SSH/`kubectl exec ... psql` para esto (a diferencia de
   lo que decía la versión original de este párrafo) — este código
   corre DENTRO del release ya desplegado en el destino (mismo momento
   en que correría el `down` real, Grupo H), así que
   `MetadataApp.Repo` ahí ya apunta al Postgres correcto sin ningún
   salto SSH aparte — SSH solo hace falta para lo que se dispara DESDE
   la laptop de dev (`imagen_actual/2`, etc.), nunca para código que ya
   corre adentro del pod destino.
5. Una migración se clasifica **automática solo si TODAS sus
   operaciones lo son** (paso 3+4) — una sola operación manual dentro
   de una migración con 5 operaciones vuelve manual la migración
   ENTERA (ejecutar el `down` de Ecto no permite correr "la mitad" de
   una migración).

`down/0` para las automáticas: Ecto ya sabe generarlo solo para el DSL
reversible de `change/0` (`create table` → `drop table`, `add` →
`remove`, `create index` → `drop index` — mecanismo nativo de
`Ecto.Migration`, cero código nuevo). El detector de arriba decide
**si es seguro dejar que Ecto lo corra solo**, no cómo revertir.

### 6.3 Ejecución + UX de bloqueo (R10b)

Cuando R10 (rollback de código) se dispara sobre un destino:
1. `PropagacionContext` identifica qué migraciones quedaron entre el
   commit actual y el commit destino del rollback (mismo `git log
   --name-only` o equivalente, filtrado a `priv/repo/migrations/`).
2. Clasifica cada una con `SeguridadMigracion.clasificar/1` (§6.2).
3. Si TODAS son automáticas: **primero el código, después la base**
   (confirmado con el usuario) — el código viejo (imagen destino del
   rollback) ignora sin problema una tabla/columna nueva que todavía
   no conoce; el riesgo real está en el orden inverso, donde el código
   nuevo (todavía corriendo un instante) podría fallar buscando algo
   que la base ya no tiene. Se aplica primero el rollback de imagen
   (R10, `propagar_extension_a_sistema` con la imagen del commit
   anterior) y recién confirmado eso, se corren los `down` de Ecto
   contra el destino (mismo canal remoto que el resto de `MotorAlta` —
   `kubectl exec` del release/`ecto.migrate` empaquetado en la imagen,
   mismo binario que ya corre `/app/bin/setup`).
4. Si AL MENOS UNA es manual: el rollback de CÓDIGO (R10) se ofrece y
   ejecuta igual (nunca se bloquea) — pero antes de confirmar, la UI
   muestra:
   - Qué migración(es) puntual(es) frenaron el auto-rollback, con la
     operación exacta (ej. `remove :campo, :string` en
     `<archivo>.exs`) — nunca un mensaje genérico tipo "no se puede".
   - Si el motivo fue "datos reales" (paso 4 de §6.2): cuántas filas.
   - Aviso explícito: "revertir el schema queda como acción manual del
     administrador — el código SÍ se revirtió, la base de datos NO".
5. Ningún camino de este mecanismo ejecuta un `down` "a medias" ni
   intenta adivinar un revert manual — la única acción automática
   posible es correr el `down` nativo de Ecto sobre migraciones ya
   clasificadas 100% seguras.

## 7. Resumen de módulos nuevos/tocados

| Módulo | Tipo |
|---|---|
| `lib/mix/tasks/motor.propagar_extension.ex` | rename de `motor.promover.ex` + flag `--commit` |
| `lib/mix/tasks/motor.propagar_extension_a_sistema.ex` | rename de `motor.actualizar.ex` |
| `lib/mix/tasks/motor.estado_extension.ex` | nuevo |
| `lib/metadata_app/motor_alta.ex` | `disparar_actualizacion/2` con guarda de idempotencia (§3) |
| `lib/metadata_app/motor_alta/estado.ex` | nuevo (§2) |
| `lib/metadata_app/propagacion_context.ex` | nuevo (§5.1) |
| `lib/metadata_app/propagacion_context/seguridad_migracion.ex` | nuevo (§6.2) |
| `lib/metadata_app_web/live/sysadmin/propagacion_live.ex` | nuevo (§5) |
| Migración: seed permiso `sysadmin_propagacion` | nueva |

## 8. Fuera de alcance (igual que requirements.md §8)

Alta de sistema nuevo (`SPEC-SYS-0309202601`), propagación de
artefactos de negocio, ejecución del revert manual de schema (R10b
solo detecta y avisa).
