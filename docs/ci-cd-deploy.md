# CI/CD y deploy — cómo funciona

> **⚠️ Nota principal:** todos los comandos de validación/diagnóstico de este documento se corren **en el servidor de producción** (Hetzner, migrado a k3s el 2026-08-26/27 -- ver `MetadataApp.Ssh`/`mix motor.desplegar`), conectado por SSH — nunca en tu máquina local. `reiayanami.mine.nu` ya NO existe, quedó reemplazado por este servidor. Localmente no tenés k3s ni la imagen de producción corriendo.

Este documento explica el flujo completo: desde que generás un catálogo en tu máquina hasta que corre en el servidor. 

> **Nota de seguridad:** este repo es público. Cualquier host, usuario o contraseña reales (del servidor de deploy, de la base de datos, tokens) **no van en este archivo ni en ningún archivo versionado** — viven solo como variables de entorno configuradas directamente en el servidor. Acá vas a ver placeholders (`<host>`, `<password>`, etc.).

## El panorama completo

```
[Tu máquina / devcontainer]        [GitHub Actions]                  [Servidor de producción]
   compilador presente        →    ├─ validate (con compilador)  →   k3s (Kubernetes)
   mix gen.catalogos                │   compila, migra, testea       (lo hace el job deploy,
   probás en caliente              ├─ build-image (si validate OK)   por SSH, automático)
   git commit + push               │   compila release, arma
                                    │   imagen SIN compilador,
                                    │   la publica en ghcr.io
                                    └─ deploy (si build-image OK)
                                        SSH al servidor:
                                        kubectl set image + rollout
                                        + kubectl exec .../bin/setup
```

**El deploy ya es automático** — cada push a `main` que pasa `validate` y `build-image` dispara el job `deploy`, que se conecta por SSH al servidor y actualiza el Deployment de k3s solo. Ya no hace falta correr `kubectl` a mano salvo que el job falle o quieras hacer un rollback puntual.

Tres ambientes distintos, cada uno con un rol:

1. **Tu máquina (dev/builder):** tiene el compilador de Elixir instalado. Acá es donde `mix gen.catalogos` puede generar en caliente migración + schema + context + controller a partir de la metadata versionada, y el router los reconoce automáticamente. Es el único lugar donde "crear un catálogo nuevo" tiene sentido.
2. **GitHub Actions (CI):** también tiene compilador (temporalmente, en un contenedor efímero). Repite lo que hiciste localmente para verificar que no te olvidaste de commitear algo, corre los tests, y arma la imagen de producción.
3. **Servidor de producción (k3s):** **no tiene compilador**. Solo sabe correr una imagen ya armada. No puedes crear catálogos ahí — si lo intentás, no hay con qué compilarlos.


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

## Paso 3 — Deploy en el servidor (k3s)

El servidor corría **Docker Swarm** hasta el 2026-08-26/27 -- migrado a **k3s** (Kubernetes liviano, single-node) esa fecha, junto con Chatwoot/Evolution API (ver memoria del proyecto para el detalle completo). Caddy sigue siendo el único front-door en 80/443 (sin cambios), reverse-proxeando por subdominio hacia el NodePort de k3s de cada servicio.

- Namespace `metadata-stack`, con:
  - un Deployment de Postgres (`metadata-stack-postgres`, con su PVC para persistencia),
  - un Deployment de la app (`metadata-stack-app`) que corre la imagen que publicó el CI, expuesto vía Service NodePort.
- Ambos comparten el namespace y se resuelven por **DNS interno de k3s** (`chatwoot-postgres`, etc., como hostname) — no hace falta IP fija ni exponer el puerto de Postgres hacia afuera.
- La app se configura enteramente por **variables de entorno** (host/puerto/usuario/password/nombre de la base de datos, `SECRET_KEY_BASE` para firmar cookies, `PHX_HOST` con el hostname público real por el que se accede — importante: si no coincide con el hostname real, Phoenix rechaza la conexión de LiveView por seguridad).
- **SMTP para el magic-link de login** (agregado 2026-07-31, para dar de alta usuarios reales): `SMTP_RELAY`, `SMTP_USERNAME`, `SMTP_PASSWORD` (obligatorias — el release ni arranca sin ellas, mismo criterio que las de la base de datos) y `SMTP_PORT` (opcional, default `587`). Antes de esto, el Mailer usaba `Swoosh.Adapters.Local` en TODOS los ambientes — en prod eso significa que el correo de login nunca le llegaba a nadie (se "enviaba" a una bandeja en memoria que solo se ve en `/dev/mailbox`, ni montado ahí). Ya está resuelto y confirmado con correo real recibido: las variables están puestas en el servicio, el remitente (`mailer_from`) usa `SMTP_USERNAME` en vez de un placeholder (si no, Gmail acepta el envío pero el destinatario lo descarta por DMARC/SPF), y el Mailer pasa `cacerts: :public_key.cacerts_get()` explícito en `tls_options` (sin esto el handshake TLS contra Gmail falla con `:tls_failed`, ya que Erlang no usa el trust store del SO por su cuenta).

### Actualizar a una versión nueva (automático desde el job `deploy`)
Como el tag `latest` no cambia de nombre en cada build, hay que forzar a k3s a re-pullear el `latest` más reciente y recrear el pod. Esto ya lo hace solo el job `deploy` del workflow (`.github/workflows/ci.yml`) por SSH en cada push a `main`:
```
sudo k3s kubectl set image deployment/metadata-stack-app app=ghcr.io/prettycore-13/metadata_stack:latest -n metadata-stack
sudo k3s kubectl rollout restart deployment/metadata-stack-app -n metadata-stack
```
Si hace falta correrlo a mano (el job falló, o un rollback puntual), son los mismos dos comandos por SSH en el servidor. También sirve `mix motor.desplegar <ambiente>` desde tu máquina (ver "Ambientes de Deploy" más abajo) — hace exactamente esto mismo, parametrizado.

### Migraciones (automático desde el job `deploy`)
El release incluye un script propio (generado a partir de `rel/overlays/bin/migrate`, que llama a `MetadataApp.Release.migrate/0`) para correr migraciones sin necesitar `mix` (que no existe en la imagen final, porque `mix` es una herramienta del *compilador*). El job `deploy` espera a que el rollout converja y lo corre solo:
```
sudo k3s kubectl exec -n metadata-stack <pod> -- /app/bin/migrate
```

### Usuario SYSADMIN (automático desde el job `deploy`, después de migrar)
Bootstrap del usuario administrador cross-empresa (`Usuario.super_admin`) — mismo criterio que Oracle con `SYS`/`SYSTEM`: el nombre/identidad es fijo pero la contraseña se define en el momento de desplegar, nunca hardcodeada en código ni en una migración (`MetadataApp.Release.seed_sysadmin/0`, corrido vía `rel/overlays/bin/seed_sysadmin`):
```
sudo k3s kubectl exec -n metadata-stack <pod> -- /app/bin/seed_sysadmin
```
**Requiere que el Deployment tenga configuradas `SYSADMIN_EMAIL`/`SYSADMIN_PASSWORD` en su entorno** (mismo lugar donde ya viven las credenciales de DB/SMTP del servicio, en el Secret de k3s -- no en este repo ni en los secrets del workflow, que solo tiene acceso SSH). Si faltan, el comando falla fuerte con un mensaje explícito en vez de arrancar con una contraseña adivinable. Entra por contraseña (no magic-link — no depende de que haya SMTP configurado todavía), es idempotente (correrlo de nuevo con las mismas credenciales no rompe nada, y cambiar `SYSADMIN_PASSWORD` + re-correr es la forma de rotarla).

**No existe ninguna pantalla para marcar/desmarcar `super_admin` en un usuario** — a propósito: es el flag de mayor privilegio del sistema (ver/crear/unirse a CUALQUIER empresa), y dejarlo como un toggle de UI abre la puerta a otorgarlo por error. Hoy el único camino es este bootstrap, que además es idempotente: busca primero la fila que YA tiene `super_admin: true` y la actualiza (nunca crea una segunda) — así que sirve tanto para el alta inicial como para rotar el email/contraseña de esa misma cuenta más adelante.

#### Paso a paso — producción
1. Conectarte por SSH al servidor de producción (ver memoria del proyecto para el host real -- no se documenta acá, este repo es público).
2. Editar el Secret de k3s con las variables nuevas y reiniciar el pod para que las tome:
   ```
   sudo k3s kubectl set env deployment/metadata-stack-app -n metadata-stack \
     SYSADMIN_EMAIL=<email> \
     SYSADMIN_PASSWORD='<contraseña-fuerte>'
   ```
3. Esperar a que el rollout converja (`sudo k3s kubectl rollout status deployment/metadata-stack-app -n metadata-stack`).
4. Correr el seed en el pod ya actualizado:
   ```
   sudo k3s kubectl exec -n metadata-stack <pod> -- /app/bin/seed_sysadmin
   ```
   (`<pod>`: `sudo k3s kubectl get pod -n metadata-stack -l app=metadata-stack-app -o jsonpath='{.items[0].metadata.name}'`).
5. Entrar a `/meta_schema_usuario/log-in`, usar el formulario de **contraseña** (no el de magic-link) con el email/contraseña del paso 2.

#### Paso a paso — dev local
1. Exportar las mismas dos variables (además de las de `DB_*` de siempre):
   ```
   export SYSADMIN_EMAIL=sysadmin@metadata.local
   export SYSADMIN_PASSWORD='una-clave-de-al-menos-12-caracteres'
   ```
2. Correr el seed directo con `mix` (no hace falta un release compilado en dev):
   ```
   mix run -e "MetadataApp.Release.seed_sysadmin()"
   ```
3. Entrar a `http://localhost:4000/meta_schema_usuario/log-in`, formulario de contraseña, mismo email/contraseña.

**Para rotar la contraseña** (dev o prod): cambiar `SYSADMIN_PASSWORD` en el entorno y repetir el paso del seed — la cuenta se actualiza in place, nunca se duplica.

### Setup del job `deploy` (una sola vez)
El job usa `appleboy/ssh-action` con 3 secrets del repo (**Settings → Secrets and variables → Actions**, nunca en archivos versionados):
- `DEPLOY_HOST` — el hostname del servidor.
- `DEPLOY_USER` — el usuario SSH.
- `DEPLOY_SSH_KEY` — clave privada ed25519 dedicada a este deploy (no la personal de nadie). Generarla con `ssh-keygen -t ed25519 -C "github-actions-deploy@metadata_stack" -N ""`, agregar la **pública** a `~/.ssh/authorized_keys` del usuario en el servidor, y la **privada** como el secret.

## Deploy de un BC (Business Context) hecho por ADN

Todo lo de arriba despliega el **BPB** (la plataforma) — este mecanismo aparte, `mix motor.publicar <catalogo>`, despliega **un catálogo de negocio construido por ADN**, sin que su código toque nunca el repo compartido (`pty_*` está en `.gitignore` a propósito, ver "Qué se commitea y qué no" arriba).

```
[Máquina de ADN]                    [GitHub Actions]                  [Servidor de producción]
   mix motor.publicar <catalogo>  →  bc-deploy.yml (workflow_dispatch)  →  k3s
   (valida, exporta, arma           checkout de main (limpio, SIN el     (mismo kubectl set
   un .tar.gz, lo manda en          BC) + el bundle se EXTRAE ENCIMA      image de siempre)
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

**Pendiente resuelto (código listo, todavía no validado end-to-end — 2026-07-24)**: cualquier push normal a `main` reconstruía la imagen `latest` sin ningún BC embebido, "olvidando" cualquier BC publicado hasta que alguien lo volviera a publicar a mano (confirmado en vivo el 2026-07-23). Se resolvió con un mecanismo de dos partes:
- `MetaPublicador.persistir_bundle/2` sube el bundle de cada publicación como asset de un GitHub Release, uno por catálogo raíz (tag `bc-<catalogo>`, pisa el anterior con `--clobber`). El Release mismo ES el manifest de "este catálogo debe quedar siempre vivo" — no hay ningún archivo de texto aparte que mantener sincronizado ni commitear.
- `ci.yml` (job `build-image`), antes de armar la imagen, lista todos los releases `bc-*`, descarga cada bundle y lo extrae sobre el checkout — así cualquier deploy normal del BPB reconstruye la imagen con todos los BCs conocidos adentro, sin que nadie tenga que acordarse de nada.

Además, `mix motor.publicar`/el wizard de publicación (BC List → "Publicar paquete") ahora aceptan **varios catálogos raíz a la vez** — el cálculo de dependencias (cierre transitivo de referencias + orden topológico) vive en un solo lugar (`MetaSchemaContext.calcular_paquete_publicacion/1`), y el wizard nunca le pide al humano que indique el orden: lo calcula solo y lo muestra de solo lectura antes de confirmar, mismo criterio que `terraform plan`/resolución de dependencias de `npm`/Helm.

También se corrigió que agregar un campo nuevo a un catálogo ya publicado nunca actualizaba su metadata en producción (la tabla física sí, vía `ALTER TABLE`, pero `meta_campos` no se enteraba) — `MetaImportExport.importar_contexto/1` ahora sincroniza campos nuevos de un catálogo que ya existe, no solo crea catálogos nuevos.

## Estado actual

El servidor de producción (Hetzner) corre **k3s** desde el 2026-08-26/27 (migrado desde Docker Swarm) — `reiayanami.mine.nu` (el servidor de oficina viejo) ya no existe, `DEPLOY_HOST` pasó a apuntar a este mismo servidor Hetzner. Ver la memoria del proyecto para el detalle operativo (credenciales, nombres exactos de recursos) — no se documenta acá porque este archivo es público.

## Ambientes de Deploy (2026-08-16)

`ci.yml`/`bc-deploy.yml` siguen desplegando siempre al MISMO servidor: `DEPLOY_HOST`/`DEPLOY_USER`/`DEPLOY_SSH_KEY` son secrets fijos del repo, y `gh workflow run` (lo que dispara `motor.publicar`) no puede pasar secrets como input — solo strings planos. Elegir servidor en tiempo de deploy no se puede resolver ADENTRO de esos workflows sin GitHub Environments (alta manual en la UI de GitHub).

Para eso existe un camino aparte, pensado para desplegar a mano a un servidor puntual (no reemplaza el push-a-`main` automático):

- **`/sysadmin/ambientes`** (`Sysadmin.AmbientesLive`) — CRUD de servidores (host, usuario SSH, contraseña/llave privada cifradas con `MetadataApp.Encriptado`, imagen). Gateado por `sysadmin_ambientes`/`leer`, mismo mecanismo de switches por pantalla que el resto de Sysadmin (ver `Permissions.capacidades_sysadmin/0`). El campo "Servicio Docker Swarm" quedó vestigial desde la migración a k3s -- `motor.desplegar` ya no lo usa (namespace/deployment de k3s son fijos), no se borró de la pantalla para no romper el formulario sin necesidad.
- **`mix motor.desplegar <ambiente> [--imagen tag]`** — asume que la imagen YA está en `ghcr.io` (por un push a `main` normal, o por `mix motor.publicar` para un `pty_*`) y hace los mismos pasos que el job `deploy` de los workflows (`kubectl set image` + `rollout restart` + esperar el rollout + `kubectl exec .../app/bin/setup`), pero por SSH directo desde la máquina de quien lo corre, con las credenciales del ambiente elegido. Útil para reforzar un deploy en un servidor específico, o para desplegar un tag puntual (`--imagen ghcr.io/.../metadata_stack:bc-<catalogo>-<run>`) sin esperar al próximo push a `main`.
- **`/sysadmin/panel-control`** (`Sysadmin.Deploy.PanelControlLive`, 2026-08-27) — levantar una app nueva (dominio + deploy en k3s), no solo metadata_stack. Ver `MetadataApp.PanelControl.Desplegador`.
