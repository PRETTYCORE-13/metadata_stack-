defmodule MetadataApp.Caddy do
  @moduledoc """
  Agrega/actualiza un bloque de un dominio en el Caddyfile remoto y
  recarga Caddy -- extraído de
  `MetadataApp.PanelControl.Desplegador.agregar_a_caddy/3` (2026-09-07,
  SPEC-SYS-0309202601 Grupo F) para que `MetadataApp.MotorAlta` pueda
  reusar EXACTAMENTE la misma lógica (probada real en producción desde
  2026-08-31 con las primeras apps de Panel Control) en vez de duplicar
  el regex de reemplazo de bloque -- un bug arreglado ahí y no acá sería
  peor que no tener el fix en ningún lado.

  Caddy es el único front-door en 80/443 de TODO el servidor (metadata_stack,
  Panel Control, Chatwoot) -- no hay ingress controller ni cert-manager en
  k3s (verificado real, Grupo F: `kubectl get ingressclass` vacío). Un
  dominio nuevo es un bloque más acá, con HTTPS automático por dominio
  (Let's Encrypt vía Caddy, no wildcard).
  """

  @caddyfile_remoto "/home/elixir/caddy/Caddyfile"

  @doc "Contenido actual del Caddyfile remoto, tal cual. {:ok, texto} | {:error, mensaje}."
  def leer(ambiente) do
    case MetadataApp.Ssh.ejecutar(ambiente, "cat #{@caddyfile_remoto}") do
      {:ok, 0, contenido} -> {:ok, contenido}
      {:ok, codigo, salida} -> {:error, "No se pudo leer el Caddyfile remoto (código #{codigo}):\n#{salida}"}
      {:error, mensaje} -> {:error, mensaje}
    end
  end

  @doc "¿`host` ya tiene un bloque en el Caddyfile remoto? Usado para detectar colisión de dominio antes de dar de alta algo nuevo."
  def host_expuesto?(ambiente, host) do
    case leer(ambiente) do
      {:ok, contenido} -> tiene_bloque?(contenido, host)
      {:error, _} = error -> error
    end
  end

  defp tiene_bloque?(contenido, host), do: Regex.match?(patron_bloque(host), contenido)

  @doc """
  Agrega (o reemplaza si ya existía) el bloque de `host` -> `nodeport` en
  el Caddyfile remoto, y recarga Caddy. `{:ok, :agregado}` |
  `{:error, mensaje}`.
  """
  def exponer(ambiente, host, nodeport) do
    case leer(ambiente) do
      {:ok, actual} ->
        nuevo_contenido = contenido_con_bloque(actual, host, nodeport)
        escribir_y_recargar(ambiente, nuevo_contenido)

      {:error, _} = error ->
        error
    end
  end

  # Reemplaza un bloque previo para el MISMO host en vez de agregar uno
  # nuevo al lado -- sin esto, reintentar un alta cuyo bloque ya había
  # quedado escrito (ej. un intento anterior que llegó hasta acá pero
  # falló/se cortó en un paso posterior) deja DOS bloques para el mismo
  # hostname, y Caddy rechaza el archivo entero con "ambiguous site
  # definition" (encontrado real, Panel Control, primera app de prueba).
  # Asume el formato simple que este mismo código siempre escribe (sin
  # llaves anidadas dentro del bloque) -- función pura, testeable sin SSH.
  @doc false
  def contenido_con_bloque(actual, host, nodeport) do
    bloque_nuevo = """

    #{host} {
        reverse_proxy 172.17.0.1:#{nodeport}
    }
    """

    contenido_sin_bloque_previo = Regex.replace(patron_bloque(host), actual, "")

    String.trim_trailing(contenido_sin_bloque_previo) <> "\n" <> bloque_nuevo
  end

  # Ancla a INICIO DE LÍNEA (/m + ^) -- sin esto, "stable.ventaenruta.com.mx"
  # matchea como substring dentro de "unstable.ventaenruta.com.mx" (un
  # host es sufijo literal del otro). Encontrado real dando de alta
  # "stable" con "unstable" ya expuesto (Grupo F, 2026-09-07): el chequeo
  # de colisión lo frenó antes de escribir nada, pero sin el ancla
  # `Regex.replace` habría cortado "stable.ventaenruta.com.mx {...}" a
  # mitad del bloque de "unstable" y dejado un "un" huérfano colgando en
  # el Caddyfile.
  defp patron_bloque(host), do: ~r/^\n*#{Regex.escape(host)}\s*\{[^}]*\}\n?/m

  # Reescribe el archivo completo con `cat > ... <<EOF` (trunca el mismo
  # inodo) en vez de `sed -i` (crea un archivo nuevo y lo renombra encima)
  # -- el bind mount de Caddy es de un archivo suelto, no un directorio,
  # así que `sed -i` deja al contenedor viendo el contenido VIEJO a través
  # de un mount roto hasta reiniciarlo. `cat >` escribe en el inodo
  # existente, el próximo `caddy reload` lo ve bien.
  defp escribir_y_recargar(ambiente, nuevo_contenido) do
    comando = """
    set -e
    cat > #{@caddyfile_remoto} <<'METADATA_CADDYFILE_EOF'
    #{nuevo_contenido}
    METADATA_CADDYFILE_EOF
    docker exec caddy caddy reload --config /etc/caddy/Caddyfile
    """

    case MetadataApp.Ssh.ejecutar(ambiente, comando) do
      {:ok, 0, _salida} -> {:ok, :agregado}
      {:ok, codigo, salida} -> {:error, "No se pudo actualizar/recargar Caddy (código #{codigo}):\n#{salida}"}
      {:error, mensaje} -> {:error, mensaje}
    end
  end
end
