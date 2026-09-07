# SPEC-SYS-0309202601 — Alta de Sistema Nuevo

**Documento:** Design · **Fase:** ✅ aprobada (2026-09-03).

## 1. Convenciones de nombres

Todos los sistemas comparten el **mismo namespace** de k3s que ya existe
(`metadata-stack`) — no se crea un namespace por cliente. Con 10 sistemas
máximo, separar por namespace solo agrega RBAC/secrets que administrar sin
necesidad real; aislar por Deployment+Service+base de datos propia ya da el
aislamiento que importa (datos y proceso).

Dado un nombre de sistema `<sistema>` (minúsculas, solo letras/dígitos/
guiones — mismo charset que un label de Kubernetes y que un subdominio
válido, se valida una sola vez al dar de alta):

| Recurso | Nombre |
|---|---|
| Deployment / Service (k3s) | `metadata-<sistema>` |
| Base de datos (Postgres) | `db_<sistema>` |
| Secret con credenciales de conexión + claves de la app | `metadata-<sistema>-env` |
| Ingress | `metadata-<sistema>-ingress`, host `<sistema>.ventaenruta.com.mx` |
| Imagen (compartida, sin cambio) | `ghcr.io/prettycore-13/metadata_stack:latest`, pull vía `ghcr-pull-secret` (ya existe, compartido) |
| Certificado TLS (compartido, wildcard) | `*.ventaenruta.com.mx`, un solo Secret TLS referenciado por todos los Ingress |

`priv/sistemas.json` guarda solo lo que no se puede derivar del nombre:

```jsonc
{
  "crm": { "dominio": "crm.ventaenruta.com.mx", "alta": "2026-09-03" },
  "direem": { "dominio": "direem.ventaenruta.com.mx", "alta": "2026-09-10" }
}
```

Nada de namespace/deployment/secret ahí — esos se derivan siempre de la
key (`metadata-<sistema>`) para que no haya dos lugares con el mismo dato
que se puedan desincronizar.

## 2. "aws-postgres" — RDS simulado, compartido, dentro de k3s (ejecutado 2026-09-04)

**Reemplaza la idea de un `docker-compose` local por sistema (versión
anterior de esta sección)** — decidido 2026-09-04: en vez de que cada
developer simule RDS en su propia máquina, hay UN servidor Postgres
compartido corriendo DENTRO del mismo clúster k3s que aloja los sistemas —
más fiel al modelo real ("un servidor, N bases") que una copia local por
persona.

Reemplazó a un contenedor Docker Swarm suelto (`aws_postgres.1...`, stack
`aws`) que ya existía sin nada de valor adentro — se dio de baja
(`docker stack rm aws`) y se recreó administrado por k3s:

| Recurso | Nombre / valor |
|---|---|
| StatefulSet + volumen persistente (10Gi, `local-path`) | `aws-postgres`, namespace `metadata-stack` |
| Service (ClusterIP headless, sin puerto publicado al host) | `aws-postgres` — alcanzable desde cualquier pod del namespace como `aws-postgres:5432` |
| Secret con credenciales | `aws-postgres-env` (`POSTGRES_USER=appuser`, credenciales nuevas — las viejas del contenedor Swarm se dieron de baja con él) |
| Imagen | `postgres:16` (misma versión que ya traía el contenedor Swarm que reemplaza; no se subió a 17 para no introducir una variable más en el mismo cambio) |

`db_<sistema>` (§1) son bases DENTRO de este servidor — `mix motor.alta`
(§4) se conecta ahí con `DB_HOSTNAME_PSQL=aws-postgres.metadata-stack.svc.cluster.local`
para crear cada una. El día que haya AWS RDS real, cambia solo el host — la
app y el mecanismo de alta no saben ni les importa si están hablando con
esto o con RDS real (R2).

**Nota operativa real de esta ejecución**: al crear el `StatefulSet`, el
único nodo del clúster tenía el taint `node.kubernetes.io/disk-pressure`
(84% de disco usado) — nada relacionado a este spec, pero bloqueaba
programar CUALQUIER pod nuevo. Se liberó con `docker image prune -f`
(9.3GB recuperados, solo imágenes sin taggear, no tocó nada de lo que ya
corría) — vale la pena vigilar esto a futuro, cada sistema nuevo va a
sumar otra imagen más al mismo disco.

## 3. CI/CD — tres canales estilo Debian + qué cambia en cada workflow

**Reemplaza la idea de "un solo laboratorio" (versión anterior de esta
sección) — decidido 2026-09-03.** `metadata-stack-app`
(`metadata.ventaenruta.com.mx`) se recrea desde cero (no tiene nada de
valor todavía) como el primero de **tres canales**, terminología Debian:

| Canal | Sistema (mismas convenciones de §1) | Quién lo actualiza y cómo |
|---|---|---|
| **Unstable** | `metadata-unstable` / `unstable.ventaenruta.com.mx` | Automático — `ci.yml` en CADA push a `main` (mismo comportamiento que tenía `metadata-stack-app` hoy, solo renombrado). Lo último que subió Dev, sin ninguna curaduría. |
| **Testing** | `metadata-testing` / `testing.ventaenruta.com.mx` | Manual — alguien promueve explícitamente lo que ya está en Unstable. |
| **Stable** | `metadata-stable` / `stable.ventaenruta.com.mx` | Manual — alguien promueve explícitamente lo que ya está en Testing. **Único canal habilitado como origen para desplegar a un cliente real.** |

A diferencia del Debian real (ahí Unstable→Testing es automático, un
script promueve solo según criterios) acá **los dos saltos son manuales a
propósito** (decidido 2026-09-03 — "todo manual por ahora, hay otras
prioridades"). Automatizar el primer salto contra `mix test` sería barato
más adelante (`validate` de `ci.yml` ya corre la suite en cada push), pero
no es parte de este spec.

Los tres son sistemas reales en k3s (Deployment/Service/Secret/Ingress
propios, base propia `db_unstable`/`db_testing`/`db_stable`) con las MISMAS
convenciones de nombre que §1 ya define para cualquier `<sistema>` — no son
un caso especial de infraestructura, son tres entradas más del mismo
esquema. Se dan de alta una sola vez con el mismo `mix motor.alta`
(§4) que cualquier sistema — la diferencia es que NO son clientes, así que
NO entran a `priv/sistemas.json` (ese archivo es específicamente "sistemas
válidos para `--sistema=` de ADN", y ADN nunca publica un catálogo directo
contra un canal).

**`bc-deploy.yml`** — gana un input obligatorio nuevo `sistema` (junto a
`catalogo` y `bundle_b64`, ya existentes), siempre un sistema de CLIENTE
(nunca un canal). El paso SSH final calcula namespace/deployment desde ese
input (`metadata-${{ inputs.sistema }}`) en vez de los valores fijos de hoy
(`metadata-stack`/`metadata-stack-app`).

**`ci.yml`** — el job `deploy` se queda, pero apuntado siempre y solo a
`metadata-unstable` (antes `metadata-stack-app`, mismo comportamiento,
nombre nuevo). Sigue siendo 100% automático en cada push a `main` — para
eso sirve Unstable.

**Workflow nuevo — `actualizar-sistema.yml`** — mismo patrón que
`bc-deploy.yml` (SSH + `kubectl set image` + `rollout` + `bin/setup`), pero
sin bundle: dado un `sistema` y una `imagen` (tag/sha, siempre obligatorio,
nunca implícito "el último"), actualiza `metadata-<sistema>` a esa imagen.
Sirve para DOS cosas distintas con la misma mecánica:

- **Promoción entre canales** — `mix motor.promover <origen> <destino>`
  (`unstable→testing` o `testing→stable`, ningún otro par válido — no se
  saltea Testing) consulta qué imagen corre HOY en `<origen>` (mismo
  mecanismo de R8, `kubectl get deployment ... -o jsonpath=...image`) y
  llama `actualizar-sistema.yml` con esa imagen exacta sobre `<destino>`.
  No hay build nuevo — promover es mover el MISMO artefacto ya construido,
  nunca reconstruirlo.
- **Actualizar un sistema de cliente** — `mix motor.actualizar <sistema>
  <imagen>` (`<sistema>` de `priv/sistemas.json`). Acá `actualizar-
  sistema.yml` valida ADEMÁS que `<imagen>` sea la que está corriendo
  AHORA MISMO en `metadata-stable` — si no coincide, rechaza. Así ningún
  cliente puede terminar con una imagen que nunca pasó por los tres
  canales, sin importar quién dispare el comando o desde dónde.

Ambos se disparan igual que `bc-deploy.yml` — vía `gh workflow run`, sin
necesitar acceso directo al clúster — así que tanto Dev como ADN pueden
correrlos.

## 4. Mecanismo de alta — `mix motor.alta <sistema>`

Corre LOCAL, desde la laptop de Dev — ya tiene acceso SSH directo al
servidor (confirmado esta misma sesión), a diferencia de ADN no necesita
pasar por GitHub Actions para esto (R1). **Corregido 2026-09-04**: "local"
significa desde el devcontainer (Linux) — `MetadataApp.Ssh` corriendo
directo en una terminal de Windows nativa es poco confiable (verificado
real: cuelga o pierde la salida capturada), problema de cómo Erlang maneja
el proceso `ssh.exe` de Windows, no del código de este mecanismo. Andando
bien y rápido desde Linux, mismo ambiente que ya usa CI.

1. Valida `<sistema>` — charset válido (mismo que un label de k3s / un
   segmento de subdominio) y que NO exista ya, chequeando DOS fuentes:
   `priv/sistemas.json` (si es un cliente) Y k3s directo (¿ya existe un
   Deployment `metadata-<sistema>`? — cubre los canales, que nunca están
   en `sistemas.json`, y cualquier desincronización entre el archivo y la
   realidad del clúster, ver §6). Alta duplicada se rechaza si CUALQUIERA
   de las dos dice que ya existe.
2. SSH al servidor: crea la base `db_<sistema>` en el Postgres de
   producción (hoy el contenedor Docker suelto; el día que sea RDS, mismo
   comando contra el host de RDS — nada de esto cambia).
3. SSH al servidor: aplica los manifiestos de k3s — Deployment + Service +
   Secret `metadata-<sistema>-env` (credenciales de conexión a
   `db_<sistema>` + claves de la app) + Ingress con host
   `<sistema>.ventaenruta.com.mx` — templados a partir de `<sistema>`
   (§1).
4. SSH al servidor: `kubectl exec` sobre el pod recién creado, corre
   `/app/bin/setup` (R3 — migra las tablas `meta_*`, deja el sistema listo
   para el wizard de primer arranque).
5. Si `<sistema>` es un CLIENTE (no un canal): edita `priv/sistemas.json`
   localmente, agrega la entrada nueva, commitea y pushea (R4 — último
   paso; sin esto el alta se considera incompleta). Si `<sistema>` es
   `unstable`/`testing`/`stable`, este paso se salta — los canales nunca
   entran a ese archivo (§3).

## 5. R9 — corrección de timing: depende del wizard, no del mix task

`mix motor.alta` termina en el paso 4 de arriba, ANTES de que exista
ninguna Empresa en el sistema nuevo — y Branch/SalesUnit/InventoryLocation
requieren todos un `empresa_id` (los dos últimos también `branch_id`). Por
lo tanto **R9 no puede ejecutarse dentro de `mix motor.alta`** — se ejecuta
al completar el wizard de primer arranque, el único momento en que existe
una Empresa.

`Autenticacion.crear_empresa_para_usuario/2` (ya usada por
`primer_arranque.ex` y por `Release.setup/0`) se extiende para, dentro de
la MISMA transacción que ya crea la Empresa, crear también un Branch, un
SalesUnit y un InventoryLocation con valores genéricos — reusando
`Autenticacion.crear_branch/1`, `crear_sales_unit/1`,
`crear_inventory_location/1` tal cual existen hoy, con el `empresa_id`/
`branch_id` recién creados. El requisito (R9) no cambia — el sistema
termina con estos defaults igual — solo cambia CUÁNDO pasa.

**Resuelto (2026-09-03), corregido (2026-09-07)**: `pty_folio_perfiles` y
`pty_subtipos_transaccion` técnicamente son catálogos del Motor BC (mismo
mecanismo de publicación que cualquier BC de ADN), pero conceptualmente
son básicos de sistema — hacen falta para generar folios de transacciones
en cualquier sistema nuevo, no son un catálogo de negocio específico de un
cliente (el nombre `pty_` quedó por historia, no porque sean "de un
cliente" como el resto de lo que arranca con ese prefijo).

La versión original de este párrafo proponía que `mix motor.alta`
restaurara un bundle para estos dos, igual que `ci.yml` con los `bc-*` de
ADN — quedó obsoleto: la sesión de CI de este mismo día (2026-09-03) ya
dejó sus migraciones Y una migración de DATOS
(`20260903000000_registrar_catalogo_pty_folio_perfiles.exs` y su par de
`pty_subtipos_transaccion`) **permanentemente commiteadas** al repo — esa
migración registra la metadata completa (header/detail, y para
`pty_subtipos_transaccion` también estados/transiciones vía
`MetaEstadosAdmin.crear_proceso_completo/1`) directo en código Elixir, sin
depender de ningún `.meta.json`. Verificado real (2026-09-07, auditoría de
Grupo B): una base migrada 100% desde cero YA tiene los dos catálogos con
su metadata completa, sin ningún paso extra — `bin/setup` (migrar +
`import_meta`, que `mix motor.alta` ya llama en el paso 4) alcanza solo.
Grupo D queda cerrado por verificación, no por código nuevo.

## 6. Riesgo — blast radius

`mix motor.alta` corre con acceso SSH directo al MISMO servidor que aloja
todos los sistemas ya en producción — un mecanismo pensado para crear algo
nuevo, corriendo con permisos que también pueden tocar lo que ya existe.
Puntos concretos y su mitigación:

- **Colisión de nombre con un sistema existente.** Validar `<sistema>`
  solo contra `priv/sistemas.json` (§4 paso 1) no alcanza si ese archivo
  quedó desincronizado de la realidad del clúster (ver próximo punto). El
  paso 1 tiene que chequear TAMBIÉN contra k3s directo (¿ya existe un
  Deployment `metadata-<sistema>`?) antes de crear nada — dos fuentes
  tienen que coincidir en "no existe", no alcanza con una.
- **Alta parcial — pasos 1-5 no son una transacción.** Si el proceso corta
  a mitad (ej. falla el paso 4 o alguien lo interrumpe antes del paso 5),
  queda un sistema con recursos reales en k3s (DB, Deployment, Ingress)
  pero SIN registrar en `sistemas.json` — huérfano: no aparece como válido
  para `motor.publicar`/`motor.actualizar` (R5 ya lo protege ahí), pero
  tampoco queda evidencia fácil de que hay que terminarlo o limpiarlo.
  Mitigación: cada paso debe ser re-ejecutable sin duplicar (crear DB/
  aplicar manifiestos son idempotentes por naturaleza si se escriben con
  `IF NOT EXISTS`/`kubectl apply`), así correr `mix motor.alta` de nuevo
  con el mismo nombre retoma donde cortó en vez de fallar o duplicar.
- **`metadata-stack-app` se recrea desde cero como `metadata-unstable`,
  a propósito** (decidido 2026-09-03 — no tiene nada de valor todavía, se
  recrea libremente, no se migra dato ninguno). Junto con Testing y Stable,
  quedan AFUERA de `priv/sistemas.json` — ese archivo es solo para
  clientes, y `motor.publicar --sistema=` nunca puede apuntar a un canal
  (§3). El riesgo real acá es de proceso, no técnico: si alguien confunde
  un canal con un cliente (ej. corre `mix motor.actualizar unstable
  <imagen>` pensando que es un cliente), el mismo chequeo de "¿está en
  `sistemas.json`?" ya lo bloquea — `unstable`/`testing`/`stable` nunca
  están ahí, así que ese comando se rechaza igual que cualquier nombre
  inventado.
- **`ci.yml`/`bc-deploy.yml`/`actualizar-sistema.yml` son compartidos entre
  TODOS los sistemas.** Un bug en la lógica que arma `namespace`/
  `deployment` a partir de `sistema` (ej. un typo en la interpolación)
  podría apuntar el `kubectl set image` de un sistema al Deployment de
  OTRO. Mitigación: sin defaults en ningún input (ya establecido en R5/R6),
  y probar la interpolación contra un sistema de prueba antes de que
  cualquiera de estos workflows quede escribiendo en producción real.
- **Certificado TLS wildcard — un solo punto de falla compartido.** Todos
  los Ingress dependen del mismo Secret TLS. Si vence o queda mal
  configurado, los 10 sistemas pierden HTTPS al mismo tiempo, no uno.
  Mitigación: renovación automática (cert-manager + DNS-01 contra
  `*.ventaenruta.com.mx`), no un recordatorio manual — un solo certificado
  compartido exige que la renovación nunca dependa de que alguien se
  acuerde.
- **Postgres sigue siendo una sola instancia** (decisión ya tomada, §3 de
  `requirements.md`) — cada alta nueva agrega una base más a la misma
  instancia compartida. No es un riesgo nuevo de este spec, pero cada
  `mix motor.alta` lo hace un poco más real; vale la pena vigilar
  conexiones totales (`N sistemas × pool_size`) a medida que se acerque a
  los 10 clientes proyectados.
- **El gate "solo Stable puede ir a cliente" vive en un solo chequeo de
  `actualizar-sistema.yml`.** Si ese chequeo tiene un bug o alguien lo
  bypasea corriendo `kubectl` directo por SSH (Dev sí tiene ese acceso,
  §4), una imagen que nunca pasó por Testing podría terminar en un
  cliente real sin que quede ningún registro de que se saltó el proceso.
  Mitigación: el chequeo compara siempre contra lo que corre EN VIVO en
  `metadata-stable` (nunca contra un valor cacheado o copiado), y cualquier
  cambio manual por SSH que rodee el workflow queda fuera del alcance de
  este spec — es un problema de disciplina del equipo, no algo que el
  mecanismo pueda impedir técnicamente si alguien decide saltárselo a
  propósito.
