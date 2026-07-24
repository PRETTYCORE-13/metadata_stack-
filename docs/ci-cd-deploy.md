# CI/CD y deploy — cómo funciona

> **⚠️ Nota principal:** todos los comandos de validación/diagnóstico de este documento (`docker run`, `docker service ps`, `docker history`, etc.) se corren **en el servidor Linux de producción** (`reiayanami.mine.nu`), conectado por SSH — nunca en tu máquina local. Localmente no tenés Docker Swarm ni la imagen de producción corriendo.

Este documento explica el flujo completo: desde que generás un catálogo en tu máquina hasta que corre en el servidor. 

> **Nota de seguridad:** este repo es público. Cualquier host, usuario o contraseña reales (del servidor de deploy, de la base de datos, tokens) **no van en este archivo ni en ningún archivo versionado** — viven solo como variables de entorno configuradas directamente en el servidor. Acá vas a ver placeholders (`<host>`, `<password>`, etc.).

## El panorama completo

```
[Tu máquina / devcontainer]        [GitHub Actions]                  [Servidor de producción]
   compilador presente        →    ├─ validate (con compilador)  →   Docker Swarm
   mix gen.catalogos                │   compila, migra, testea       (lo hace el job deploy,
   probás en caliente              ├─ build-image (si validate OK)   por SSH, automático)
   git commit + push               │   compila release, arma
                                    │   imagen SIN compilador,
                                    │   la publica en ghcr.io
                                    └─ deploy (si build-image OK)
                                        SSH al servidor:
                                        docker pull + service update
                                        + docker exec .../bin/migrate
```

**El deploy ya es automático** — cada push a `main` que pasa `validate` y `build-image` dispara el job `deploy`, que se conecta por SSH al servidor y actualiza el servicio solo. Ya no hace falta correr `docker pull`/`docker service update` a mano salvo que el job falle o quieras hacer un rollback puntual.

Tres ambientes distintos, cada uno con un rol:

1. **Tu máquina (dev/builder):** tiene el compilador de Elixir instalado. Acá es donde `mix gen.catalogos` puede generar en caliente migración + schema + context + controller a partir de la metadata versionada, y el router los reconoce automáticamente. Es el único lugar donde "crear un catálogo nuevo" tiene sentido.
2. **GitHub Actions (CI):** también tiene compilador (temporalmente, en un contenedor efímero). Repite lo que hiciste localmente para verificar que no te olvidaste de commitear algo, corre los tests, y arma la imagen de producción.
3. **Servidor de producción (Docker Swarm):** **no tiene compilador**. Solo sabe correr una imagen ya armada. No podés crear catálogos ahí — si lo intentás, no hay con qué compilarlos.


## Paso 1 — Local: generar y probar un catálogo

Con el compilador de Elixir disponible, corrés las tareas mix que generan un catálogo nuevo (migración, schema Ecto, context, controller) a partir de la metadata versionada (Business Contexts). Lo probás ahí mismo. Cuando estás conforme, commiteás el código generado + la metadata.

## Qué se commitea y qué no — BPB (core) vs BC (`pty_*`)

Este repo es el **BPB** (Business Process Builder): la plataforma compartida que usa todo el equipo (Uriel, Liz, Jesus). Los **BC** (Business Contexts) que cada uno genera probando el motor — catálogos con prefijo **`pty_*`** — son "micro apps" que cada desarrollador arma localmente con el BPB, no código de la plataforma. **Nunca van a este repo, ni de prueba ni reales.**

El discriminador es puramente de nombre, ya establecido en todo el proyecto: **`meta_schema_*`/`Meta*`** = core del BPB, siempre se commitea. **`pty_*`** = BC generado, nunca se commitea. Formalizado en `.gitignore` (agregado 2026-07-23):
```
lib/metadata_app/meta_business_process/catalogos/pty_*.ex
lib/metadata_app/meta_business_process/reglas/pty_*/
priv/repo/catalogos/pty_*.json
priv/repo/migrations/*pty_*.exs
```
Cualquier `pty_*` que generes localmente (catálogo, regla, export, migración) nunca aparece en `git status` — no hace falta acordarte de no commitearlo, Git ya no lo deja. El mismo día se hizo una limpieza retroactiva de todo `pty_*` que ya estaba trackeado de sesiones anteriores (`git rm --cached` + borrado en disco, commit `0647531`).

**Efecto colateral real sobre el job `validate`**: el paso 3 de CI ("importa la metadata versionada y regenera todos los catálogos") ahora no tiene ningún `pty_*.meta.json`/`.motor.json` para importar — nunca hay un BC real corriendo por el pipeline de CI. El chequeo de drift (paso 4) sigue siendo válido para el core del BPB, pero **ya no ejercita el ciclo completo de generación de un catálogo de negocio real**. Si hace falta volver a probar ese ciclo en CI, va a necesitar un catálogo de ejemplo que viva bajo otro prefijo (no `pty_*`) pensado a propósito para eso, no uno real de ADN.

**Pendiente sin resolver todavía**: cómo llega un BC de verdad (compilado por ADN con el BPB) a Linux Trixie (producción) **sin pasar por este repo** — hoy el único camino a producción es el que describe este documento (push → CI → imagen), que es exclusivamente para el BPB. Ese mecanismo para BCs es diseño nuevo, no existe todavía.

## Paso 2 — `git push` dispara el CI

El workflow vive en [`.github/workflows/ci.yml`](../.github/workflows/ci.yml) y tiene dos jobs:

### Job `validate`
Corre en un runner de GitHub (Ubuntu, con Elixir instalado). Repite el mismo proceso que hiciste local:
1. Instala dependencias (`mix deps.get`).
2. Migra una base de test vacía.
3. Importa la metadata versionada y vuelve a generar **todos** los catálogos (`mix gen.catalogos`).
4. Compara con `git status` si esa generación produjo algún archivo que no está commiteado — si hay diferencia, **falla el build**. Esto evita que alguien commitee la metadata pero se olvide de commitear el código generado (o viceversa).
5. Compila con `--warning-as-errors` y corre los tests.


### Job `build-image` (solo si `validate` pasó)
Arma la imagen de producción usando el [`Dockerfile`](../Dockerfile), que tiene **dos etapas**:

- **Etapa `builder`** (imagen `hexpm/elixir`, con compilador completo): instala dependencias, compila, y corre `mix release`. Esto genera un **release de OTP**: un paquete autocontenido que incluye tu código ya compilado a bytecode (`.beam`) **más su propia copia del runtime de Erlang (ERTS)**. 
- **Etapa final** (imagen `debian:trixie-slim`, sin ningún compilador ni SDK): copia únicamente el release ya armado de la etapa anterior. El resultado es una imagen mínima que solo sabe ejecutar `bin/server` — no puede compilar nada aunque quisiera.

Esa imagen final se publica en GitHub Container Registry: `ghcr.io/prettycore-13/metadata_stack:latest` (y con el tag del SHA del commit).

**Dos detalles de packaging con los que nos topamos** (por si el workflow rompe de nuevo con un error parecido):
- Docker exige que los tags de imagen estén en **minúsculas** — `github.repository` viene con mayúsculas, así que el workflow lo convierte explícitamente.
- Docker no permite que un nombre de imagen **termine en un separador** (`-`, `.`, `_`) — como el nombre del repo termina en guion, el workflow lo recorta antes de armar el tag.

## Paso 3 — Deploy en el servidor (Docker Swarm)

El servidor corre **Docker Swarm** (no `docker run` suelto, ni `docker-compose` plano).Administra "servicios" que Docker mantiene corriendo, reinicia si se caen, y conecta entre sí por una red virtual propia.

- Existe un **stack** (grupo de servicios relacionados) llamado `metadata_stack`, con:
  - un servicio de Postgres ya existente (para persistencia),
  - un servicio de la app (`metadata_stack_app`) que corre la imagen que publicó el CI.
- Ambos servicios comparten una **red overlay** (una red virtual privada entre contenedores del mismo stack), así que la app puede conectarse a la base de datos usando el **nombre del servicio** como si fuera un hostname (Swarm resuelve DNS interno automáticamente) — no hace falta IP fija ni exponer el puerto de Postgres hacia afuera.
- La app se configura enteramente por **variables de entorno** (host/puerto/usuario/password/nombre de la base de datos, `SECRET_KEY_BASE` para firmar cookies, `PHX_HOST` con el hostname público real por el que se accede — importante: si no coincide con el hostname real, Phoenix rechaza la conexión de LiveView por seguridad).

### Actualizar a una versión nueva (automático desde el job `deploy`)
Como el tag `latest` no cambia de nombre en cada build, hay que forzar a Swarm a resolver el `latest` más reciente y recrear el contenedor. Esto ya lo hace solo el job `deploy` del workflow (`.github/workflows/ci.yml`) por SSH en cada push a `main`:
```
docker pull ghcr.io/prettycore-13/metadata_stack:latest
docker service update --image ghcr.io/prettycore-13/metadata_stack:latest --force metadata_stack_app
```
Si hace falta correrlo a mano (el job falló, o un rollback puntual), son los mismos dos comandos por SSH en el servidor.

### Migraciones (automático desde el job `deploy`)
El release incluye un script propio (generado a partir de `rel/overlays/bin/migrate`, que llama a `MetadataApp.Release.migrate/0`) para correr migraciones sin necesitar `mix` (que no existe en la imagen final, porque `mix` es una herramienta del *compilador*). El job `deploy` espera a que el servicio converja y lo corre solo:
```
docker exec <container_id> /app/bin/migrate
```

### Setup del job `deploy` (una sola vez)
El job usa `appleboy/ssh-action` con 3 secrets del repo (**Settings → Secrets and variables → Actions**, nunca en archivos versionados):
- `DEPLOY_HOST` — el hostname del servidor.
- `DEPLOY_USER` — el usuario SSH.
- `DEPLOY_SSH_KEY` — clave privada ed25519 dedicada a este deploy (no la personal de nadie). Generarla con `ssh-keygen -t ed25519 -C "github-actions-deploy@metadata_stack" -N ""`, agregar la **pública** a `~/.ssh/authorized_keys` del usuario en el servidor, y la **privada** como el secret.

## Deploy de un BC (Business Context) hecho por ADN

Todo lo de arriba despliega el **BPB** (la plataforma) — este mecanismo aparte, `mix motor.publicar <catalogo>`, despliega **un catálogo de negocio construido por ADN**, sin que su código toque nunca el repo compartido (`pty_*` está en `.gitignore` a propósito, ver "Qué se commitea y qué no" arriba).

```
[Máquina de ADN]                    [GitHub Actions]                  [Servidor de producción]
   mix motor.publicar <catalogo>  →  bc-deploy.yml (workflow_dispatch)  →  Docker Swarm
   (valida, exporta, arma           checkout de main (limpio, SIN el     (mismo docker service
   un .tar.gz, lo manda en          BC) + el bundle se EXTRAE ENCIMA      update de siempre)
   base64 vía "gh workflow run")    → compila → build-image → deploy
```

**Por qué nunca toca `origin/main`**: el workflow hace `actions/checkout@v4` de `main` tal cual está, y el bundle del BC se extrae sobre el working directory EFÍMERO de ese runner — ni un `git add`, ni commit, ni push en ningún paso. Cuando el job termina, el runner se destruye junto con esos archivos; el repo remoto nunca se enteró de que ese BC existió.

**Qué lleva el bundle** (armado por `mix motor.publicar`, ver `lib/mix/tasks/motor.publicar.ex`): por el catálogo pedido, sus catálogos detalle si es maestro (mismo criterio que el botón "Despliegue" de BC List), **y todo catálogo que referencie** (`tipo: "referencia"`), recursivo —
- `lib/.../catalogos/<catalogo>.ex` (el schema ya generado)
- `priv/repo/migrations/*<catalogo>*.exs` (sus migraciones)
- `priv/repo/catalogos/<catalogo>.meta.json` (+ `.motor.json` si tiene autómata propio)
- `lib/.../reglas/<catalogo>/` (si tiene reglas de negocio)

**Credenciales**: `mix motor.publicar` no ve ni necesita ninguna — corre enteramente con `gh` (GitHub CLI) autenticado, y el workflow reusa los mismos 3 secrets ya configurados para el deploy del BPB (`DEPLOY_HOST`/`DEPLOY_USER`/`DEPLOY_SSH_KEY`) más el `GITHUB_TOKEN` de siempre para `ghcr.io`. Nadie necesita copiar credenciales de producción a su máquina para publicar un BC.

**Por qué no hot code loading**: se evaluó compilar el BC en la máquina de ADN y cargar los `.beam` directo en el nodo BEAM vivo del servidor (nativo de Erlang/OTP, cero downtime). Se descartó por seguridad (sin un artefacto inmutable/auditable de por medio — en los hechos, ejecución de código arbitrario contra quien tenga la SSH key), por escalabilidad (no sirve solo si algún día Swarm corre más de una réplica, sin repetir el hot-load en cada una a mano) y porque el patrón de imagen+rollback ya está construido y probado — hot-loading hubiera sido un mecanismo nuevo y frágil al lado de uno que ya funciona.

**Probado real de punta a punta contra producción** (no solo local) el 2026-07-23 con `pty_crm_comando_enc` — quedó corriendo de verdad en `reiayanami.mine.nu`, confirmado con un `GET /api/pty_crm_comando_enc` real. El primer intento falló dos veces antes de salir bien — ver los 3 bugs reales de abajo, todos corregidos el mismo día.

### 3 bugs reales encontrados en la primera corrida (y cómo se corrigieron)

Una simulación local previa (armar el bundle + `docker build`) había salido limpia, pero no alcanzó para agarrar estos tres — solo aparecieron corriendo contra producción de verdad:

1. **El bundle no arrastraba catálogos referenciados.** `pty_crm_comando_enc` tiene dos campos `referencia` (a `pty_crm_empresa` y `pty_crm_segmento`). Como era el primer BC desplegado, esos catálogos nunca habían existido en producción — la migración de `pty_crm_comando_enc` intentaba crear una FK contra una tabla inexistente y fallaba (`relation "pty_crm_empresa" does not exist`). **Fix**: `mix motor.publicar` ahora calcula el cierre transitivo de dependencias (A referencia a B, B referencia a C → se empaquetan los tres), mismo criterio que el orden topológico que ya usa `mix gen.catalogos`.

2. **La migración crea la tabla, pero nadie importaba la metadata.** Después del fix #1, la migración corrió bien — pero la API seguía respondiendo `"Registro no encontrado"`. Causa: `docker exec ... /app/bin/migrate` crea la tabla FÍSICA, pero nunca hubo un paso que poblara `meta_schema_header`/`detail`/`estados`/`transiciones` — en producción no hay `mix`, así que `mix meta.import`/`mix motor.import` no se pueden correr ahí. **Fix**: nueva `MetadataApp.Release.import_meta/0` + `rel/overlays/bin/import_meta` (mismo patrón que `bin/migrate`), que el workflow corre justo después de migrar. La lógica de importación se sacó de los `Mix.Tasks.Meta.Import`/`Motor.Import` hacia `MetadataApp.MetaImportExport` (un módulo sin ninguna dependencia de `Mix`) para que tanto el task como el release compartan el mismo código.

3. **La ruta relativa `"priv/repo/catalogos"` no resuelve en un release compilado.** Al escribir `import_meta`, el primer intento seguía sin encontrar los `.json` — `File.ls("priv/repo/catalogos")` devolvía `{:error, :enoent}`. En un release OTP, el `priv/` real de la app vive en `/app/lib/metadata_app-<vsn>/priv/...`, no en el directorio desde donde corre el proceso — una ruta relativa literal solo funciona corriendo con `mix` (que siempre se ejecuta desde la raíz del proyecto). **Fix**: `Application.app_dir(:metadata_app, "priv/repo/catalogos")`, la forma correcta de resolver esto en cualquier contexto (dev, test, o un release).

**Gotcha aparte, solo para quien reproduzca esta prueba en Windows**: simular el build de Docker localmente (`git archive` + overlay + `docker build`) en una máquina con `core.autocrlf=true` convierte los scripts de `rel/overlays/bin/*` a CRLF, y `#!/bin/sh` con `\r` no corre. El blob real commiteado siempre tiene LF (confirmado con `git show HEAD:...`) — el problema es solo de la simulación local en Windows, nunca del runner Linux real de GitHub Actions. Si hace falta repetir la simulación, correr `sed -i 's/\r$//'` sobre esos scripts antes de `docker build`.

**Pendiente real, sin resolver**: cualquier push normal a `main` (deploy del BPB solo, vía `ci.yml`) reconstruye la imagen `latest` **sin ningún BC embebido** — pisa la imagen que tenía el BC. Un BC publicado con `motor.publicar` queda "olvidado" en el próximo deploy normal del BPB hasta que se vuelva a publicar. Sin diseñar todavía cómo hacer que convivan.

## Estado actual

El servidor de oficina (`reiayanami.mine.nu`) funciona hoy como **producción simulada** — todavía no hay un ambiente de staging separado. El objetivo de esta etapa es dominar el proceso de punta a punta antes de sumar más ambientes. Ver la memoria del proyecto para el detalle operativo (credenciales, nombres exactos de servicios) — no se documenta acá porque este archivo es público.
