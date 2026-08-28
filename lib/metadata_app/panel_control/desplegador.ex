defmodule MetadataApp.PanelControl.Desplegador do
  @moduledoc """
  Orquesta el alta de una `MetadataApp.PanelControl.App`: DNS (Cloudflare)
  -> deploy en k3s (por SSH, reusando MetadataApp.Ssh) -> exponerla detrás
  de Caddy (mismo patrón ya probado a mano en la migración a k3s,
  2026-08-26: Caddy sigue siendo el único front-door en 80/443, cada app
  nueva es un bloque más en su Caddyfile apuntando al NodePort de k3s vía
  `172.17.0.1`, igual que ya hace para metadata_stack/Chatwoot).

  DNS vía `MetadataApp.PanelControl.Cloudflare`, no Hostinger -- los
  dominios reales de esta cuenta (`ventaenruta.com.mx`) tienen sus
  *nameservers* apuntando a Cloudflare, no a Hostinger (que sigue siendo
  el REGISTRADOR, pero no quien resuelve DNS de verdad). Encontrado real
  2026-08-28: `Hostinger.crear_registro_a/3` "funcionaba" (sin error) pero
  el registro nunca resolvía. `Hostinger.ex` queda en el código por si
  algún dominio futuro sí use sus nameservers.

  Namespace fijo `panel-control` para todo lo creado desde acá -- separado
  de `metadata-stack`/`chatwoot` (los servicios migrados), así un
  `kubectl get pods -n panel-control` muestra sólo lo que salió de esta
  pantalla.
  """

  alias MetadataApp.{Ambientes, PanelControl}
  alias MetadataApp.PanelControl.{App, Cloudflare}

  @namespace "panel-control"
  @caddyfile_remoto "/home/elixir/caddy/Caddyfile"

  @doc "Punto de entrada: DNS -> deploy -> Caddy -> guarda el resultado en `app`. Siempre devuelve {:ok, %App{}} (con estado \"activo\" o \"error\")."
  def crear_app(%App{} = app) do
    ambiente = Ambientes.obtener_ambiente!(app.ambiente_id)

    resultado =
      with :ok <- Cloudflare.crear_registro_a(app.dominio_base, app.subdominio, ambiente.host),
           {:ok, nodeport} <- desplegar_en_k8s(ambiente, app),
           :ok <- agregar_a_caddy(ambiente, app, nodeport) do
        {:ok, %{estado: "activo", nodeport: nodeport, ultimo_error: nil}}
      end

    case resultado do
      {:ok, attrs} -> PanelControl.actualizar_estado(app, attrs)
      {:error, motivo} -> PanelControl.actualizar_estado(app, %{estado: "error", ultimo_error: motivo})
    end
  end

  defp desplegar_en_k8s(ambiente, app) do
    comando = """
    set -e
    cat <<'PANEL_CONTROL_MANIFEST_EOF' | sudo k3s kubectl apply -f -
    apiVersion: v1
    kind: Namespace
    metadata:
      name: #{@namespace}
    ---
    apiVersion: apps/v1
    kind: Deployment
    metadata:
      name: #{app.subdominio}
      namespace: #{@namespace}
    spec:
      replicas: 1
      selector:
        matchLabels:
          app: #{app.subdominio}
      template:
        metadata:
          labels:
            app: #{app.subdominio}
        spec:
          containers:
            - name: app
              image: #{app.imagen_docker}
    #{bloque_env(app.variables_entorno)}
              ports:
                - containerPort: #{app.puerto_interno}
    ---
    apiVersion: v1
    kind: Service
    metadata:
      name: #{app.subdominio}
      namespace: #{@namespace}
    spec:
      type: NodePort
      selector:
        app: #{app.subdominio}
      ports:
        - port: #{app.puerto_interno}
          targetPort: #{app.puerto_interno}
    PANEL_CONTROL_MANIFEST_EOF
    sudo k3s kubectl rollout status deployment/#{app.subdominio} -n #{@namespace} --timeout=90s
    sudo k3s kubectl get svc #{app.subdominio} -n #{@namespace} -o jsonpath='{.spec.ports[0].nodePort}'
    """

    case MetadataApp.Ssh.ejecutar(ambiente, comando) do
      {:ok, 0, salida} ->
        case salida |> String.trim() |> String.split("\n") |> List.last() |> Integer.parse() do
          {nodeport, _resto} -> {:ok, nodeport}
          :error -> {:error, "El deploy en k3s terminó bien pero no se pudo leer el nodeport de la salida:\n#{salida}"}
        end

      {:ok, codigo, salida} ->
        {:error, "El deploy en k3s terminó con código #{codigo}:\n#{salida}"}

      {:error, mensaje} ->
        {:error, mensaje}
    end
  end

  defp bloque_env(variables) when map_size(variables) == 0, do: ""

  defp bloque_env(variables) do
    entradas =
      Enum.map_join(variables, "\n", fn {clave, valor} ->
        "        - name: #{clave}\n          value: #{inspect(to_string(valor))}"
      end)

    "      env:\n#{entradas}\n"
  end

  # Reescribe el archivo completo con `cat > ... <<EOF` (trunca el mismo
  # inodo) en vez de `sed -i` (crea un archivo nuevo y lo renombra encima)
  # -- encontrado real migrando Chatwoot/metadata_stack a k3s: el bind
  # mount de Caddy es de un archivo suelto, no un directorio, así que
  # `sed -i` deja al contenedor viendo el contenido VIEJO a través de un
  # mount roto (el nuevo inodo nunca le llega) hasta reiniciarlo. `cat >`
  # escribe en el inodo existente, el próximo `caddy reload` lo ve bien.
  defp agregar_a_caddy(ambiente, app, nodeport) do
    with {:ok, 0, actual} <- MetadataApp.Ssh.ejecutar(ambiente, "cat #{@caddyfile_remoto}") do
      host = "#{app.subdominio}.#{app.dominio_base}"

      bloque_nuevo = """

      #{host} {
          reverse_proxy 172.17.0.1:#{nodeport}
      }
      """

      # Reemplaza un bloque previo para el MISMO host en vez de agregar
      # uno nuevo al lado -- sin esto, reintentar una app cuyo bloque ya
      # había quedado escrito (ej. un intento anterior que llegó hasta acá
      # pero falló/se cortó en un paso posterior) deja DOS bloques para el
      # mismo hostname, y Caddy rechaza el archivo entero con "ambiguous
      # site definition" (encontrado real reintentando la primera app de
      # prueba). Asume el formato simple que este mismo código siempre
      # escribe (sin llaves anidadas dentro del bloque).
      contenido_sin_bloque_previo =
        Regex.replace(~r/\n*#{Regex.escape(host)}\s*\{[^}]*\}\n?/, actual, "")

      nuevo_contenido = String.trim_trailing(contenido_sin_bloque_previo) <> "\n" <> bloque_nuevo

      comando = """
      set -e
      cat > #{@caddyfile_remoto} <<'PANEL_CONTROL_CADDYFILE_EOF'
      #{nuevo_contenido}
      PANEL_CONTROL_CADDYFILE_EOF
      docker exec caddy caddy reload --config /etc/caddy/Caddyfile
      """

      case MetadataApp.Ssh.ejecutar(ambiente, comando) do
        {:ok, 0, _salida} -> :ok
        {:ok, codigo, salida} -> {:error, "No se pudo actualizar/recargar Caddy (código #{codigo}):\n#{salida}"}
        {:error, mensaje} -> {:error, mensaje}
      end
    else
      {:ok, codigo, salida} -> {:error, "No se pudo leer el Caddyfile remoto (código #{codigo}):\n#{salida}"}
      {:error, mensaje} -> {:error, mensaje}
    end
  end
end
