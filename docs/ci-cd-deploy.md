# CI/CD y deploy — cómo funciona

Este documento explica el flujo completo: desde que generás un catálogo en tu máquina hasta que corre en el servidor. Está pensado para alguien que viene de .NET/C# y es nuevo en Elixir, CI/CD y Docker — así que incluye analogías donde ayudan.

> **Nota de seguridad:** este repo es público. Cualquier host, usuario o contraseña reales (del servidor de deploy, de la base de datos, tokens) **no van en este archivo ni en ningún archivo versionado** — viven solo como variables de entorno configuradas directamente en el servidor. Acá vas a ver placeholders (`<host>`, `<password>`, etc.).

## El panorama completo

```
[Tu máquina / devcontainer]        [GitHub]                          [Servidor de producción]
   compilador presente        →    Actions (CI)              →       Docker Swarm
   mix gen.catalogos               ├─ validate (con compilador)       ├─ docker pull imagen nueva
   probás en caliente              │   compila, migra, testea         ├─ docker service update --force
   git commit + push               └─ build-image (si validate OK)    └─ docker exec .../bin/migrate
                                        compila release, arma
                                        imagen SIN compilador,
                                        la publica en ghcr.io
```

Tres ambientes distintos, cada uno con un rol:

1. **Tu máquina (dev/builder):** tiene el compilador de Elixir instalado. Acá es donde `mix gen.catalogos` puede generar en caliente migración + schema + context + controller a partir de la metadata versionada, y el router los reconoce automáticamente. Es el único lugar donde "crear un catálogo nuevo" tiene sentido.
2. **GitHub Actions (CI):** también tiene compilador (temporalmente, en un contenedor efímero). Repite lo que hiciste localmente para verificar que no te olvidaste de commitear algo, corre los tests, y arma la imagen de producción.
3. **Servidor de producción (Docker Swarm):** **no tiene compilador**. Solo sabe correr una imagen ya armada. No podés crear catálogos ahí — si lo intentás, no hay con qué compilarlos.

Analogía con .NET: es como tener tu build en Debug en tu máquina, un pipeline de Azure DevOps/GitHub Actions que hace `dotnet build` + `dotnet test`, y después `dotnet publish --self-contained` empaquetando un ejecutable que no necesita el SDK de .NET instalado en el servidor — solo el runtime (o ni eso, si es self-contained). La diferencia es que acá el "self-contained" lo arma `mix release`, y en vez de copiar el ejecutable directamente al servidor, se empaqueta todo dentro de una imagen Docker que viaja por un container registry.

## Paso 1 — Local: generar y probar un catálogo

Con el compilador de Elixir disponible, corrés las tareas mix que generan un catálogo nuevo (migración, schema Ecto, context, controller) a partir de la metadata versionada (Business Contexts). Lo probás ahí mismo. Cuando estás conforme, commiteás el código generado + la metadata.

## Paso 2 — `git push` dispara el CI

El workflow vive en [`.github/workflows/ci.yml`](../.github/workflows/ci.yml) y tiene dos jobs:

### Job `validate`
Corre en un runner de GitHub (Ubuntu, con Elixir instalado). Repite el mismo proceso que hiciste local:
1. Instala dependencias (`mix deps.get`).
2. Migra una base de test vacía.
3. Importa la metadata versionada y vuelve a generar **todos** los catálogos (`mix gen.catalogos`).
4. Compara con `git status` si esa generación produjo algún archivo que no está commiteado — si hay diferencia, **falla el build**. Esto evita que alguien commitee la metadata pero se olvide de commitear el código generado (o viceversa).
5. Compila con `--warning-as-errors` y corre los tests.

Analogía: es como un job de CI que corre `dotnet build` + `dotnet test`, pero además valida que un generador de código (piensa en un source generator, o en Entity Framework migrations) no haya quedado desincronizado del código versionado.

### Job `build-image` (solo si `validate` pasó)
Arma la imagen de producción usando el [`Dockerfile`](../Dockerfile), que tiene **dos etapas**:

- **Etapa `builder`** (imagen `hexpm/elixir`, con compilador completo): instala dependencias, compila, y corre `mix release`. Esto genera un **release de OTP**: un paquete autocontenido que incluye tu código ya compilado a bytecode (`.beam`) **más su propia copia del runtime de Erlang (ERTS)**. Es la parte más distinta de .NET — no es como copiar solo el ejecutable, es empaquetar el equivalente a "mi código + una JVM/CLR entera dedicada a él".
- **Etapa final** (imagen `debian:trixie-slim`, sin ningún compilador ni SDK): copia únicamente el release ya armado de la etapa anterior. El resultado es una imagen mínima que solo sabe ejecutar `bin/server` — no puede compilar nada aunque quisiera.

Esa imagen final se publica en GitHub Container Registry: `ghcr.io/prettycore-13/metadata_stack:latest` (y con el tag del SHA del commit).

**Dos detalles de packaging con los que nos topamos** (por si el workflow rompe de nuevo con un error parecido):
- Docker exige que los tags de imagen estén en **minúsculas** — `github.repository` viene con mayúsculas, así que el workflow lo convierte explícitamente.
- Docker no permite que un nombre de imagen **termine en un separador** (`-`, `.`, `_`) — como el nombre del repo termina en guion, el workflow lo recorta antes de armar el tag.

## Paso 3 — Deploy en el servidor (Docker Swarm)

El servidor corre **Docker Swarm** (no `docker run` suelto, ni `docker-compose` plano). Conceptualmente, para alguien de .NET: pensalo como una versión liviana de un orquestador (similar en espíritu a Service Fabric o un Kubernetes chico) — administra "servicios" que Docker mantiene corriendo, reinicia si se caen, y conecta entre sí por una red virtual propia.

- Existe un **stack** (grupo de servicios relacionados) llamado `metadata_stack`, con:
  - un servicio de Postgres ya existente (para persistencia),
  - un servicio de la app (`metadata_stack_app`) que corre la imagen que publicó el CI.
- Ambos servicios comparten una **red overlay** (una red virtual privada entre contenedores del mismo stack), así que la app puede conectarse a la base de datos usando el **nombre del servicio** como si fuera un hostname (Swarm resuelve DNS interno automáticamente) — no hace falta IP fija ni exponer el puerto de Postgres hacia afuera.
- La app se configura enteramente por **variables de entorno** (host/puerto/usuario/password/nombre de la base de datos, `SECRET_KEY_BASE` para firmar cookies, `PHX_HOST` con el hostname público real por el que se accede — importante: si no coincide con el hostname real, Phoenix rechaza la conexión de LiveView por seguridad).

### Actualizar a una versión nueva
Como el tag `latest` no cambia de nombre en cada build, hay que forzar a Swarm a resolver el `latest` más reciente y recrear el contenedor:
```
docker pull ghcr.io/prettycore-13/metadata_stack:latest
docker service update --image ghcr.io/prettycore-13/metadata_stack:latest --force metadata_stack_app
```

### Migraciones
El release incluye un script propio (generado a partir de `rel/overlays/bin/migrate`, que llama a `MetadataApp.Release.migrate/0`) para correr migraciones sin necesitar `mix` (que no existe en la imagen final, porque `mix` es una herramienta del *compilador*):
```
docker exec <container_id> /app/bin/migrate
```

## Estado actual

El servidor de oficina (`reiayanami.mine.nu`) funciona hoy como **producción simulada** — todavía no hay un ambiente de staging separado. El objetivo de esta etapa es dominar el proceso de punta a punta antes de sumar más ambientes. Ver la memoria del proyecto para el detalle operativo (credenciales, nombres exactos de servicios) — no se documenta acá porque este archivo es público.
