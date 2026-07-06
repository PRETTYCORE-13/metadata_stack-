# Imagen de desarrollo. Usa la MISMA versión de Elixir/OTP/Debian que el
# builder de producción (ver ../Dockerfile, generado por `mix phx.gen.release`)
# para que "funciona en el devcontainer" y "funciona en el build de release"
# sean literalmente el mismo entorno — así se elimina el problema de compilar
# en Windows y desplegar en Linux.
ARG ELIXIR_VERSION=1.18.4
ARG OTP_VERSION=28.0.4
ARG DEBIAN_VERSION=trixie-20260610-slim

FROM docker.io/hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
     build-essential git inotify-tools postgresql-client curl ca-certificates \
  && rm -rf /var/lib/apt/lists/*

RUN mix local.hex --force \
  && mix local.rebar --force

WORKDIR /app

# El container queda vivo para que cada dev entre con una terminal (VS Code
# Dev Containers, o `docker compose exec app bash`) y corra
# `mix phx.server` a mano — no arranca el server solo.
CMD ["sleep", "infinity"]
