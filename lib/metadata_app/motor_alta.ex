defmodule MetadataApp.MotorAlta do
  @moduledoc """
  Mecanismo de alta de un sistema nuevo (SPEC-SYS-0309202601). Lógica
  compartida con `mix motor.alta` — el task es solo la interfaz de línea
  de comandos.

  Grupo B, tarea 7 (`docs/specs/SPEC-SYS-0309202601-alta-sistema-nuevo/tasks.md`):
  solo el paso de validación (design.md §4 punto 1) — charset del nombre y
  que no exista ya en `priv/sistemas.json`. El chequeo contra k3s directo
  (segunda fuente que pide design.md §4/§6) se agrega en una tarea
  posterior, cuando exista la parte que sí toca SSH.
  """

  @doc """
  Charset válido para `<sistema>`: mismo que un label de Kubernetes y un
  segmento de subdominio (RFC 1123) — minúsculas, dígitos, guiones: no
  puede empezar ni terminar en guión, máximo 63 caracteres.
  """
  def charset_valido?(sistema) when is_binary(sistema) do
    String.length(sistema) <= 63 and Regex.match?(~r/^[a-z0-9]([a-z0-9-]*[a-z0-9])?$/, sistema)
  end

  @doc """
  Ruta real de `priv/sistemas.json`. `Application.app_dir/2` en vez de una
  ruta relativa -- tiene que funcionar igual corriendo desde un checkout
  de dev que desde un release compilado (mismo criterio que
  `Release.import_meta/0`).
  """
  def ruta_sistemas, do: Application.app_dir(:metadata_app, "priv/sistemas.json")

  @doc """
  Lee un archivo de sistemas y devuelve el mapa completo (`%{}` si no
  existe todavía o está vacío). `path` por default es el real
  (`ruta_sistemas/0`) -- parametrizable para tests, sin tocar nunca el
  archivo real desde ahí.
  """
  def leer_sistemas(path \\ ruta_sistemas()) do
    case File.read(path) do
      {:ok, contenido} ->
        case Jason.decode(contenido) do
          {:ok, mapa} when is_map(mapa) -> mapa
          _ -> %{}
        end

      {:error, _} ->
        %{}
    end
  end

  @doc "¿`sistema` ya está registrado en el archivo de sistemas?"
  def sistema_registrado?(sistema, path \\ ruta_sistemas()) do
    Map.has_key?(leer_sistemas(path), sistema)
  end

  @doc """
  Valida un nombre de sistema para dar de alta -- charset y que no esté
  ya registrado. `{:ok, sistema}` | `{:error, mensaje}`.
  """
  def validar_nombre(sistema, path \\ ruta_sistemas())

  def validar_nombre(sistema, path) when is_binary(sistema) do
    cond do
      sistema == "" ->
        {:error, "El nombre del sistema no puede estar vacío."}

      not charset_valido?(sistema) ->
        {:error,
         "\"#{sistema}\" no es un nombre válido -- solo minúsculas, dígitos y guiones, sin empezar ni terminar en guión (mismo charset que un subdominio)."}

      sistema_registrado?(sistema, path) ->
        {:error, "\"#{sistema}\" ya está registrado en priv/sistemas.json -- no se puede dar de alta dos veces."}

      true ->
        {:ok, sistema}
    end
  end

  @doc """
  Crea `db_<sistema>` dentro de "aws-postgres" (design.md §2) -- por SSH
  contra `ambiente` (`%MetadataApp.Ambientes.Ambiente{}`, mismo mecanismo
  que ya usa `mix motor.desplegar`, ver `MetadataApp.Ssh`), corriendo
  `psql` DENTRO del pod (`kubectl exec`) porque el Service de
  "aws-postgres" es ClusterIP sin puerto publicado -- no hay forma de
  conectarse directo desde la laptop de Dev, solo desde otro pod/proceso
  ADENTRO del clúster (design.md §2 y §6).

  `{:ok, salida}` | `{:error, mensaje}`. Todavía NO es idempotente --
  correr esto dos veces con el mismo `sistema` falla la segunda vez
  ("database already exists"); la idempotencia es la tarea 12 de
  `tasks.md` (Grupo B), a propósito, para verificarla como su propio paso.
  """
  def crear_base(ambiente, sistema) do
    # Comillas dobles en el identificador -- sistema puede tener guiones
    # (charset_valido?/1 los permite), y "CREATE DATABASE db_direem-2"
    # sin comillas rompe (guión no es válido en un identificador SQL sin
    # comillas).
    comando =
      "sudo k3s kubectl exec -n metadata-stack aws-postgres-0 -- psql -U appuser -d postgres -c 'CREATE DATABASE \"db_#{sistema}\";'"

    case MetadataApp.Ssh.ejecutar(ambiente, comando) do
      {:ok, 0, salida} -> {:ok, salida}
      {:ok, _codigo, salida} -> {:error, salida}
      {:error, _} = error -> error
    end
  end

  @doc "SECRET_KEY_BASE o CLOAK_KEY nuevos -- nunca se comparten entre sistemas (aislamiento real, no solo de datos)."
  def generar_clave_base64(bytes \\ 64) do
    :crypto.strong_rand_bytes(bytes) |> Base.encode64()
  end

  @doc """
  Genera el YAML de los 4 recursos de k3s para `sistema` (design.md §1/§4
  paso 3) -- Secret propio (solo lo que NO se puede compartir: claves +
  lo que varía por sistema), Deployment, Service, Ingress. NO los aplica
  (`kubectl apply` es la tarea siguiente, paso 4).

  `imagen` -- el tag completo (`ghcr.io/.../metadata_stack:<tag>`), nunca
  default a `:latest`: un sistema de cliente nuevo arranca en la imagen
  que hoy corre en Stable (mismo principio que R6 -- ningún cliente
  arranca con algo que no pasó por los 3 canales), un canal nuevo
  (unstable/testing/stable) arranca en lo que se le indique a mano.

  **Dependencias que este manifiesto asume que YA existen** (no las crea
  este mecanismo):
  - `ghcr-pull-secret` (namespace `metadata-stack`) -- ya existe, compartido.
  - `aws-postgres-env` -- ya existe (design.md §2); el Deployment
    referencia sus keys `POSTGRES_USER`/`POSTGRES_PASSWORD` directo (nunca
    copia la contraseña a un Secret nuevo -- un solo lugar con la
    credencial real de la base compartida).
  - `smtp-compartido` (SMTP_RELAY/USERNAME/PASSWORD/PORT) -- **todavía NO
    existe, hace falta crearlo una sola vez** (no es parte de este
    mecanismo -- son credenciales reales de correo, no algo que generar).
  - `wildcard-ventaenruta-tls` (Secret TLS) -- tampoco existe todavía,
    tarea del Grupo F (cert-manager).
  """
  def manifiestos_k3s(sistema, imagen) do
    secret_key_base = generar_clave_base64()
    cloak_key = generar_clave_base64(32)

    """
    apiVersion: v1
    kind: Secret
    metadata:
      name: metadata-#{sistema}-env
      namespace: metadata-stack
    type: Opaque
    stringData:
      DB_NAME_PSQL: "db_#{sistema}"
      PHX_HOST: "#{sistema}.ventaenruta.com.mx"
      PORT: "4000"
      PHX_SERVER: "true"
      SECRET_KEY_BASE: "#{secret_key_base}"
      CLOAK_KEY: "#{cloak_key}"
    ---
    apiVersion: v1
    kind: Service
    metadata:
      name: metadata-#{sistema}
      namespace: metadata-stack
    spec:
      selector:
        app: metadata-#{sistema}
      ports:
        - port: 4000
          targetPort: 4000
    ---
    apiVersion: apps/v1
    kind: Deployment
    metadata:
      name: metadata-#{sistema}
      namespace: metadata-stack
    spec:
      replicas: 1
      selector:
        matchLabels:
          app: metadata-#{sistema}
      template:
        metadata:
          labels:
            app: metadata-#{sistema}
        spec:
          imagePullSecrets:
            - name: ghcr-pull-secret
          containers:
            - name: app
              image: #{imagen}
              envFrom:
                - secretRef:
                    name: metadata-#{sistema}-env
              env:
                - name: DB_HOSTNAME_PSQL
                  value: "aws-postgres"
                - name: DB_PORT_PSQL
                  value: "5432"
                - name: DB_USERNAME_PSQL
                  valueFrom:
                    secretKeyRef:
                      name: aws-postgres-env
                      key: POSTGRES_USER
                - name: DB_PASSWORD_PSQL
                  valueFrom:
                    secretKeyRef:
                      name: aws-postgres-env
                      key: POSTGRES_PASSWORD
                - name: SMTP_RELAY
                  valueFrom:
                    secretKeyRef:
                      name: smtp-compartido
                      key: SMTP_RELAY
                - name: SMTP_USERNAME
                  valueFrom:
                    secretKeyRef:
                      name: smtp-compartido
                      key: SMTP_USERNAME
                - name: SMTP_PASSWORD
                  valueFrom:
                    secretKeyRef:
                      name: smtp-compartido
                      key: SMTP_PASSWORD
                - name: SMTP_PORT
                  valueFrom:
                    secretKeyRef:
                      name: smtp-compartido
                      key: SMTP_PORT
              ports:
                - containerPort: 4000
    ---
    apiVersion: networking.k8s.io/v1
    kind: Ingress
    metadata:
      name: metadata-#{sistema}-ingress
      namespace: metadata-stack
    spec:
      tls:
        - hosts:
            - #{sistema}.ventaenruta.com.mx
          secretName: wildcard-ventaenruta-tls
      rules:
        - host: #{sistema}.ventaenruta.com.mx
          http:
            paths:
              - path: /
                pathType: Prefix
                backend:
                  service:
                    name: metadata-#{sistema}
                    port:
                      number: 4000
    """
  end

  @doc """
  Aplica el YAML de `manifiestos_k3s/2` (paso 3 -> paso 4 de §4) y corre
  `/app/bin/setup` sobre el pod recién creado -- una sola conexión SSH,
  un solo script remoto (mismo patrón que `ci.yml`/`bc-deploy.yml`).

  `MetadataApp.Ssh.ejecutar/2` corre siempre con stdin en /dev/null (`-n`
  fijo en `correr/4`) -- no hay forma de pipear el YAML por stdin.
  Mismo problema, misma solución que ya usa `MetaPublicador.disparar_deploy/2`
  para el bundle de un BC: base64 embebido en el comando, decodeado del
  otro lado.

  Pod race (mismo bug real que ya se encontró y arregló en `ci.yml`,
  2026-09-03, ver el comentario largo ahí): ordenar por
  `creationTimestamp` y tomar el último -- nunca `items[0]` sin ordenar,
  que puede agarrar un pod viejo todavía Terminating.

  `{:ok, salida}` | `{:error, mensaje}`.
  """
  def aplicar_manifiestos(ambiente, sistema, imagen) do
    yaml_b64 = manifiestos_k3s(sistema, imagen) |> Base.encode64()

    comando = """
    echo #{yaml_b64} | base64 -d | sudo k3s kubectl apply -f - && \
    sudo k3s kubectl rollout status deployment/metadata-#{sistema} -n metadata-stack --timeout=120s && \
    POD=$(sudo k3s kubectl get pod -n metadata-stack -l app=metadata-#{sistema} --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[*].metadata.name}' | awk '{print $NF}') && \
    sudo k3s kubectl exec -n metadata-stack "$POD" -- /app/bin/setup
    """
    |> String.trim()

    case MetadataApp.Ssh.ejecutar(ambiente, comando) do
      {:ok, 0, salida} -> {:ok, salida}
      {:ok, _codigo, salida} -> {:error, salida}
      {:error, _} = error -> error
    end
  end
end
