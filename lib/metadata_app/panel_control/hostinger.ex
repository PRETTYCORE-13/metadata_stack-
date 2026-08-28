defmodule MetadataApp.PanelControl.Hostinger do
  @moduledoc """
  Registra el subdominio de una `MetadataApp.PanelControl.App` en Hostinger
  (registro DNS tipo A -> IP del `Ambiente` de destino) vía su API REST,
  usando el token guardado en `MetadataApp.Integraciones.Credencial`
  (`sistema_externo: "hostinger"`) -- la cuenta Hostinger ya está conectada
  por MCP para uso de Claude, pero la app en producción necesita su propia
  copia del token para llamar la API en runtime.

  Formato del body armado a partir de la documentación pública de la API
  de Hostinger (`PUT /api/dns/v1/zones/{dominio}`).

  El host real de la API es `developers.hostinger.com` -- `api.hostinger.com`
  (el default original acá) no resuelve contra un origen válido y devuelve
  530/"error code: 1016" (Cloudflare "Origin DNS error"), encontrado real
  probando esto contra la cuenta de producción (2026-08-27).
  """

  require Logger

  @doc """
  Crea (o reemplaza si ya existe) el registro A de `subdominio` en la zona
  de `dominio_base`, apuntando a `ip_destino` -- `overwrite: true`, no
  `false`: acá siempre queremos que ESTE subdominio apunte a ESTA IP, sin
  importar si ya había un registro previo (ej. un intento anterior que
  falló en un paso posterior, ver Desplegador.crear_app/1 -- el DNS es el
  primer paso, así que un reintento SIEMPRE pisa lo que haya quedado del
  intento anterior). Hostinger solo reemplaza el registro que matchea
  nombre+tipo, no toca el resto de la zona (encontrado real: con
  `overwrite: false` un reintento fallaba con "[DNS:4008] ... conflicts
  with another resource record").
  """
  def crear_registro_a(dominio_base, subdominio, ip_destino) do
    case MetadataApp.Integraciones.obtener_credencial_por_sistema("hostinger") do
      nil ->
        {:error, "No hay ninguna credencial de Hostinger configurada -- creá una en /sysadmin/credenciales con sistema_externo \"hostinger\"."}

      credencial ->
        url = (credencial.base_url || "https://developers.hostinger.com") <> "/api/dns/v1/zones/#{dominio_base}"

        body = %{
          overwrite: true,
          zone: [
            %{name: subdominio, type: "A", ttl: 300, records: [%{content: ip_destino}]}
          ]
        }

        case Req.put(url, json: body, headers: [{"authorization", "Bearer #{credencial.api_key}"}], receive_timeout: 15_000, retry: false) do
          {:ok, %Req.Response{status: status}} when status in 200..299 ->
            :ok

          {:ok, %Req.Response{status: status, body: resp_body}} ->
            {:error, "Hostinger devolvió HTTP #{status}: #{inspect(resp_body)}"}

          {:error, motivo} ->
            {:error, "No se pudo contactar a Hostinger: #{inspect(motivo)}"}
        end
    end
  rescue
    e -> {:error, "Excepción llamando a Hostinger: #{Exception.message(e)}"}
  end
end
