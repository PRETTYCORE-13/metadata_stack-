defmodule MetadataApp.PanelControl.Cloudflare do
  @moduledoc """
  Registra el subdominio de una `MetadataApp.PanelControl.App` en Cloudflare
  (registro DNS tipo A -> IP del `Ambiente` de destino) vía su API REST,
  usando el token guardado en `MetadataApp.Integraciones.Credencial`
  (`sistema_externo: "cloudflare"`).

  Reemplaza a `MetadataApp.PanelControl.Hostinger` para dominios cuyos
  *nameservers* apuntan a Cloudflare en vez de a Hostinger (ej.
  `ventaenruta.com.mx`, confirmado real 2026-08-28: la API de Hostinger
  "aceptaba" el pedido sin error, pero el registro nunca resolvía de
  verdad -- Hostinger seguía siendo el REGISTRADOR del dominio, pero
  Cloudflare es quien de verdad resuelve las consultas DNS). Hostinger.ex
  queda sin usar acá pero no se borra -- sigue siendo válido para un
  dominio que sí use los nameservers de Hostinger.

  `proxied: false` (nube gris, no naranja) a propósito -- Caddy necesita
  poder validar el desafío ACME contra el ORIGEN real para emitir su
  propio certificado Let's Encrypt; proxyear a través de Cloudflare
  agregaría una capa de SSL/proxy extra que Panel Control no está
  pensado para manejar hoy.
  """

  require Logger

  @base_url_default "https://api.cloudflare.com/client/v4"

  @doc """
  Crea (o actualiza si ya existe) el registro A de `subdominio` en la
  zona de `dominio_base`, apuntando a `ip_destino`.
  """
  def crear_registro_a(dominio_base, subdominio, ip_destino) do
    case MetadataApp.Integraciones.obtener_credencial_por_sistema("cloudflare") do
      nil ->
        {:error, "No hay ninguna credencial de Cloudflare configurada -- creá una en /sysadmin/credenciales con sistema_externo \"cloudflare\"."}

      credencial ->
        with {:ok, zone_id} <- obtener_zone_id(credencial, dominio_base),
             {:ok, registro_id} <- buscar_registro(credencial, zone_id, subdominio, dominio_base) do
          guardar_registro(credencial, zone_id, registro_id, subdominio, dominio_base, ip_destino)
        end
    end
  rescue
    e -> {:error, "Excepción llamando a Cloudflare: #{Exception.message(e)}"}
  end

  defp obtener_zone_id(credencial, dominio_base) do
    case get(credencial, "/zones", name: dominio_base) do
      {:ok, %{"result" => [%{"id" => zone_id} | _]}} ->
        {:ok, zone_id}

      {:ok, %{"result" => []}} ->
        {:error, "Cloudflare no tiene ninguna zona para \"#{dominio_base}\" -- ¿el dominio está agregado a esta cuenta de Cloudflare?"}

      {:error, mensaje} ->
        {:error, mensaje}
    end
  end

  defp buscar_registro(credencial, zone_id, subdominio, dominio_base) do
    host = "#{subdominio}.#{dominio_base}"

    case get(credencial, "/zones/#{zone_id}/dns_records", type: "A", name: host) do
      {:ok, %{"result" => [%{"id" => registro_id} | _]}} -> {:ok, registro_id}
      {:ok, %{"result" => []}} -> {:ok, nil}
      {:error, mensaje} -> {:error, mensaje}
    end
  end

  # registro_id == nil -> crear (POST); si no, actualizar el existente
  # (PUT) -- idempotente a propósito, mismo motivo que overwrite=true en
  # Hostinger.ex: un reintento de Desplegador.crear_app/1 (ej. porque un
  # paso posterior falló la primera vez) no debe chocar con el registro
  # que un intento anterior ya dejó creado.
  defp guardar_registro(credencial, zone_id, nil, subdominio, dominio_base, ip_destino) do
    body = %{type: "A", name: "#{subdominio}.#{dominio_base}", content: ip_destino, ttl: 300, proxied: false}

    case post(credencial, "/zones/#{zone_id}/dns_records", body) do
      {:ok, %{"success" => true}} -> :ok
      {:ok, resp} -> {:error, "Cloudflare no pudo crear el registro: #{inspect(resp["errors"])}"}
      {:error, mensaje} -> {:error, mensaje}
    end
  end

  defp guardar_registro(credencial, zone_id, registro_id, subdominio, dominio_base, ip_destino) do
    body = %{type: "A", name: "#{subdominio}.#{dominio_base}", content: ip_destino, ttl: 300, proxied: false}

    case put(credencial, "/zones/#{zone_id}/dns_records/#{registro_id}", body) do
      {:ok, %{"success" => true}} -> :ok
      {:ok, resp} -> {:error, "Cloudflare no pudo actualizar el registro: #{inspect(resp["errors"])}"}
      {:error, mensaje} -> {:error, mensaje}
    end
  end

  defp get(credencial, path, params) do
    request(:get, credencial, path, params: params)
  end

  defp post(credencial, path, body) do
    request(:post, credencial, path, json: body)
  end

  defp put(credencial, path, body) do
    request(:put, credencial, path, json: body)
  end

  defp request(metodo, credencial, path, opts) do
    url = (credencial.base_url || @base_url_default) <> path
    headers = [{"authorization", "Bearer #{credencial.api_key}"}]
    req_opts = [method: metodo, url: url, headers: headers, receive_timeout: 15_000, retry: false] ++ opts

    case Req.request(req_opts) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, "Cloudflare devolvió HTTP #{status}: #{inspect(body)}"}

      {:error, motivo} ->
        {:error, "No se pudo contactar a Cloudflare: #{inspect(motivo)}"}
    end
  end
end
