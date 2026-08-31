defmodule MetadataApp.PanelControl.PlantillasPhoenix do
  @moduledoc """
  Contenido literal de los archivos que `MetadataApp.PanelControl.Github`
  commitea en un repo Phoenix nuevo para poder armar/publicar/desplegar su
  imagen solo -- copiado 1:1 de lo que se armó y probó a mano contra
  producción real (repo `imagen-docker`/CRM, 2026-08-31: `mix
  phx.gen.release --docker` + el workflow de `.github/workflows/ci.yml`
  de este mismo proyecto), solo parametrizado por el nombre de la app.

  `rel/overlays/bin/{server,migrate}` van con permiso ejecutable
  (100755) al commitearlos vía la Git Data API en `Github` -- ESE es el
  motivo real de usar esa API en vez de la Contents API (que solo sabe
  crear archivos en 100644): commitear estos dos scripts sin el bit de
  ejecución hace que el contenedor final crashee en loop con "permission
  denied" al arrancar (bug real encontrado a mano esta misma sesión,
  causado por `core.filemode=false` en un checkout de Windows -- acá ni
  siquiera pasa por un checkout local, así que ese bug entero queda
  descartado de raíz).
  """

  @doc "Dockerfile de dos etapas (builder con compilador -> runner sin él), igual al de este propio proyecto y al de imagen-docker/CRM."
  def dockerfile(app_snake) do
    """
    ARG ELIXIR_VERSION=1.18.4
    ARG OTP_VERSION=28.1
    ARG DEBIAN_VERSION=trixie-20260610-slim

    ARG BUILDER_IMAGE="docker.io/hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"
    ARG RUNNER_IMAGE="docker.io/debian:${DEBIAN_VERSION}"

    FROM ${BUILDER_IMAGE} AS builder

    RUN apt-get update \\
      && apt-get install -y --no-install-recommends build-essential git \\
      && rm -rf /var/lib/apt/lists/*

    WORKDIR /app

    RUN mix local.hex --force \\
      && mix local.rebar --force

    ENV MIX_ENV="prod"

    COPY mix.exs mix.lock ./
    RUN mix deps.get --only $MIX_ENV
    RUN mkdir config

    COPY config/config.exs config/${MIX_ENV}.exs config/
    RUN mix deps.compile

    RUN mix assets.setup

    COPY priv priv

    COPY lib lib

    RUN mix compile

    COPY assets assets

    RUN mix assets.deploy

    COPY config/runtime.exs config/

    COPY rel rel
    RUN mix release

    FROM ${RUNNER_IMAGE} AS final

    RUN apt-get update \\
      && apt-get install -y --no-install-recommends libstdc++6 openssl libncurses6 locales ca-certificates \\
      && rm -rf /var/lib/apt/lists/*

    RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen \\
      && locale-gen

    ENV LANG=en_US.UTF-8
    ENV LANGUAGE=en_US:en
    ENV LC_ALL=en_US.UTF-8

    WORKDIR "/app"
    RUN chown nobody /app

    ENV MIX_ENV="prod"

    COPY --from=builder --chown=nobody:root /app/_build/${MIX_ENV}/rel/#{app_snake} ./

    USER nobody

    CMD ["/app/bin/server"]
    """
  end

  def dockerignore do
    """
    .dockerignore
    .git
    !.git/HEAD
    !.git/refs
    /cover/
    /doc/
    /test/
    /tmp/
    .elixir_ls
    /_build/
    /deps/
    *.ez
    erl_crash.dump
    /assets/node_modules/
    /priv/static/assets/
    /priv/static/cache_manifest.json
    """
  end

  @doc "lib/<app_snake>/release.ex -- `app_camel` es el nombre del módulo OTP (ej. \"Crm\"), `app_snake` el átomo de la app (ej. \"crm\")."
  def release_ex(app_camel, app_snake) do
    """
    defmodule #{app_camel}.Release do
      @moduledoc \"\"\"
      Used for executing DB release tasks when run in production without Mix
      installed.
      \"\"\"
      @app :#{app_snake}

      def migrate do
        load_app()

        for repo <- repos() do
          {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
        end
      end

      def rollback(repo, version) do
        load_app()
        {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
      end

      defp repos do
        Application.fetch_env!(@app, :ecto_repos)
      end

      defp load_app do
        Application.ensure_all_started(:ssl)
        Application.ensure_loaded(@app)
      end
    end
    """
  end

  def overlay_server(app_snake) do
    """
    #!/bin/sh
    set -eu

    cd -P -- "$(dirname -- "$0")"
    PHX_SERVER=true exec ./#{app_snake} start
    """
  end

  def overlay_migrate(app_camel, app_snake) do
    """
    #!/bin/sh
    set -eu

    cd -P -- "$(dirname -- "$0")"
    exec ./#{app_snake} eval #{app_camel}.Release.migrate
    """
  end

  @doc """
  CI de 3 jobs (validate/build-image/deploy), igual al que arma y publica
  la imagen de este propio proyecto y del CRM -- `k8s_deployment` es el
  nombre del Deployment/Service en k3s (= subdominio de la futura App en
  Panel Control), namespace fijo "panel-control" (separado de
  metadata-stack/chatwoot, ver `MetadataApp.PanelControl.Desplegador`).
  """
  def ci_yml(app_snake, k8s_deployment) do
    """
    name: CI

    on:
      push:
        branches: [main]
      pull_request:
        branches: [main]

    env:
      ELIXIR_VERSION: "1.18.4"
      OTP_VERSION: "28.1"

    jobs:
      validate:
        runs-on: ubuntu-latest
        env:
          MIX_ENV: test

        services:
          postgres:
            image: postgres:17
            env:
              POSTGRES_USER: postgres
              POSTGRES_PASSWORD: postgres
              POSTGRES_DB: #{app_snake}_test
            ports: ["5432:5432"]
            options: >-
              --health-cmd pg_isready
              --health-interval 10s
              --health-timeout 5s
              --health-retries 5

        steps:
          - uses: actions/checkout@v4

          - uses: erlef/setup-beam@v1
            with:
              elixir-version: ${{ env.ELIXIR_VERSION }}
              otp-version: ${{ env.OTP_VERSION }}

          - name: Cache deps
            uses: actions/cache@v4
            with:
              path: |
                deps
                _build
              key: ${{ runner.os }}-mix-${{ hashFiles('mix.lock') }}
              restore-keys: ${{ runner.os }}-mix-

          - name: Instalar dependencias
            run: mix deps.get

          - name: Crear y migrar base de test
            run: |
              mix ecto.create
              mix ecto.migrate

          - name: Compilar sin warnings
            run: mix compile --warning-as-errors

          - name: Test
            run: mix test

      build-image:
        needs: validate
        if: github.event_name == 'push' && github.ref == 'refs/heads/main'
        runs-on: ubuntu-latest
        permissions:
          contents: read
          packages: write

        steps:
          - uses: actions/checkout@v4

          - name: Nombre de imagen para ghcr.io (minúsculas, sin separador final)
            run: |
              repo="${GITHUB_REPOSITORY,,}"
              repo="${repo%[-._]}"
              echo "IMAGE_NAME=$repo" >> "$GITHUB_ENV"

          - uses: docker/login-action@v3
            with:
              registry: ghcr.io
              username: ${{ github.actor }}
              password: ${{ secrets.GITHUB_TOKEN }}

          - uses: docker/build-push-action@v6
            with:
              context: .
              file: ./Dockerfile
              push: true
              tags: |
                ghcr.io/${{ env.IMAGE_NAME }}:latest
                ghcr.io/${{ env.IMAGE_NAME }}:${{ github.sha }}

      # Requiere 3 secrets en el repo (Settings -> Secrets and variables ->
      # Actions): DEPLOY_HOST, DEPLOY_USER, DEPLOY_SSH_KEY -- los carga
      # MetadataApp.PanelControl.Github al scaffoldear este workflow,
      # reusando la misma llave SSH compartida para todos los repos que
      # arma Panel Control (ver MetadataApp.PanelControl.DeploySsh).
      deploy:
        needs: build-image
        if: github.event_name == 'push' && github.ref == 'refs/heads/main'
        runs-on: ubuntu-latest

        steps:
          - name: Actualizar #{k8s_deployment} en k3s y migrar
            uses: appleboy/ssh-action@v1
            with:
              host: ${{ secrets.DEPLOY_HOST }}
              username: ${{ secrets.DEPLOY_USER }}
              key: ${{ secrets.DEPLOY_SSH_KEY }}
              script: |
                set -e
                sudo k3s kubectl rollout restart deployment/#{k8s_deployment} -n panel-control
                sudo k3s kubectl rollout status deployment/#{k8s_deployment} -n panel-control --timeout=120s

                POD=$(sudo k3s kubectl get pod -n panel-control -l app=#{k8s_deployment} -o jsonpath='{.items[0].metadata.name}')
                if [ -z "$POD" ]; then
                  echo "No se encontró el pod de #{k8s_deployment}, no se pudo migrar"
                  exit 1
                fi
                sudo k3s kubectl exec -n panel-control "$POD" -- /app/bin/migrate
    """
  end
end
