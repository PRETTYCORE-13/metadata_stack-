# Find eligible builder and runner images on Docker Hub. We use Ubuntu/Debian
# instead of Alpine to avoid DNS resolution issues in production.
#
# https://hub.docker.com/r/hexpm/elixir/tags?name=ubuntu
# https://hub.docker.com/_/ubuntu/tags
#
# This file is based on these images:
#
#   - https://hub.docker.com/r/hexpm/elixir/tags - for the build image
#   - https://hub.docker.com/_/debian/tags?name=trixie-20260610-slim - for the release image
#   - https://pkgs.org/ - resource for finding needed packages
#   - Ex: docker.io/hexpm/elixir:1.18.4-erlang-28.0.4-debian-trixie-20260610-slim
#
ARG ELIXIR_VERSION=1.18.4
ARG OTP_VERSION=28.0.4
ARG DEBIAN_VERSION=trixie-20260610-slim

ARG BUILDER_IMAGE="docker.io/hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"
ARG RUNNER_IMAGE="docker.io/debian:${DEBIAN_VERSION}"

FROM ${BUILDER_IMAGE} AS builder

# install build dependencies
#
# libsodium-dev: MetadataApp.PanelControl.Github (Panel Control > "Generar
# imagen desde repositorio") usa el NIF `enacl` (only: :prod en mix.exs --
# esta máquina de dev en Windows no tiene compilador de C) para cifrar los
# secrets de GitHub Actions vía crypto_box_seal. Sin esto acá, la compilación
# del NIF falla directo en este builder stage.
RUN apt-get update \
  && apt-get install -y --no-install-recommends build-essential git libsodium-dev \
  && rm -rf /var/lib/apt/lists/*

# prepare build dir
WORKDIR /app

# install hex + rebar
RUN mix local.hex --force \
  && mix local.rebar --force

# set build ENV
ENV MIX_ENV="prod"

# install mix dependencies
COPY mix.exs mix.lock ./
RUN mix deps.get --only $MIX_ENV
RUN mkdir config

# copy compile-time config files before we compile dependencies
# to ensure any relevant config change will trigger the dependencies
# to be re-compiled.
COPY config/config.exs config/${MIX_ENV}.exs config/

# CFLAGS: el NIF `enacl` (ver libsodium-dev más arriba) está sin
# mantenimiento desde 2021 -- su C source (enacl_nif.c) pasa
# `enacl_crypto_unload` (firma de "upgrade") donde ERL_NIF_INIT espera la
# firma de "unload", algo que gcc siempre toleró como warning y que las
# versiones más nuevas (las que trae este builder) tratan como error por
# default. -Wno-error=incompatible-pointer-types lo vuelve a dejar como
# warning nada más -- no cambia el binario resultante, solo el gate del
# compilador. Encontrado real 2026-09-03: bloqueaba TODO el build de
# producción (falla igual en OTP 27 y 28, no es un tema de versión de
# OTP -- confirmado local con Docker antes de este fix).
ENV CFLAGS="-Wno-error=incompatible-pointer-types"
RUN mix deps.compile

RUN mix assets.setup

COPY priv priv

COPY lib lib

# Compile the release
RUN mix compile

COPY assets assets

# compile assets
RUN mix assets.deploy

# Changes to config/runtime.exs don't require recompiling the code
COPY config/runtime.exs config/

COPY rel rel
RUN mix release

# start a new build stage so that the final image will only contain
# the compiled release and other runtime necessities
FROM ${RUNNER_IMAGE} AS final

# openssh-client: MetadataApp.Ssh (Panel Control, motor.desplegar) shellea
# contra el binario `ssh` del sistema para conectarse a los Ambientes -- a
# diferencia de mix motor.desplegar (siempre corre en la máquina de un
# desarrollador, que ya tiene ssh), Panel Control dispara ese mismo código
# DESDE la propia app ya desplegada, adentro de este contenedor -- sin este
# paquete falla con "Erlang error: :enoent" (encontrado real, 2026-08-27).
#
# libsodium23: el NIF `enacl` (ver libsodium-dev más arriba) queda linkeado
# dinámicamente contra libsodium -- compilar bien en el builder stage NO
# alcanza, sin la librería compartida ACÁ el release arranca bien pero
# crashea recién al primer intento real de cifrar un secret de GitHub
# (mismo patrón de falla que ya describe este comentario para openssh-client).
RUN apt-get update \
  && apt-get install -y --no-install-recommends libstdc++6 openssl libncurses6 locales ca-certificates openssh-client libsodium23 \
  && rm -rf /var/lib/apt/lists/*

# Set the locale
RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen \
  && locale-gen

ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8

WORKDIR "/app"
RUN chown nobody /app

# set runner ENV
ENV MIX_ENV="prod"

# Only copy the final release from the build stage
COPY --from=builder --chown=nobody:root /app/_build/${MIX_ENV}/rel/metadata_app ./

USER nobody

# If using an environment that doesn't automatically reap zombie processes, it is
# advised to add an init process such as tini via `apt-get install`
# above and adding an entrypoint. See https://github.com/krallin/tini for details
# ENTRYPOINT ["/tini", "--"]

CMD ["/app/bin/server"]
