# Imagen de desarrollo. Usa la MISMA versión de Elixir/OTP/Debian que el
# builder de producción (ver ../Dockerfile, generado por `mix phx.gen.release`)
# para que "funciona en el devcontainer" y "funciona en el build de release"
# sean literalmente el mismo entorno — así se elimina el problema de compilar
# en Windows y desplegar en Linux.
ARG ELIXIR_VERSION=1.18.4
ARG OTP_VERSION=28.0.4
ARG DEBIAN_VERSION=trixie-20260610-slim

FROM docker.io/hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}

# gh -- mix motor.publicar/motor.actualizar/motor.promover lo necesitan
# para disparar workflows (`gh workflow run`), y el registro de un alta
# nueva en priv/sistemas.json necesita `git push` -- por eso también
# `gh auth setup-git` como parte del setup de cada dev (ver
# docs/onboarding-nuevo-sistema.md §6), no algo que se pueda hornear acá
# (depende de la identidad de GitHub de cada uno).
RUN apt-get update \
  && apt-get install -y --no-install-recommends \
     build-essential git inotify-tools postgresql-client curl ca-certificates gh \
  && rm -rf /var/lib/apt/lists/*

RUN mix local.hex --force \
  && mix local.rebar --force

WORKDIR /app

# El container queda vivo para que cada dev entre con una terminal (VS Code
# Dev Containers, o `docker compose exec app bash`) y corra
# `mix phx.server` a mano — no arranca el server solo.
CMD ["sleep", "infinity"]
