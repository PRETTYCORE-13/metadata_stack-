defmodule MetadataApp.PanelControl.Hostinger do
  @moduledoc """
  Registra el subdominio de una `MetadataApp.PanelControl.App` en Hostinger
  (registro DNS tipo A -> IP del `Ambiente` de destino) vía su API REST,
  usando el token guardado en `MetadataApp.Integraciones.Credencial`
  (`sistema_externo: "hostinger"`) -- la cuenta Hostinger ya está conectada
  por MCP para uso de Claude, pero la app en producción necesita su propia
  copia del token para llamar la API en runtime.

  Formato del body armado a partir de la documentación pública de la API
  de Hostinger (`PUT /api/dns/v1/zones/{dominio}`, developers.hostinger.com)
  -- no verificado todavía contra una llamada real (no hay token de prueba
  a mano en este entorno). Antes de usar esto por primera vez de verdad,
  confirmar el shape exacto del body contra la cuenta real y ajustar acá
  si hace falta.
  """

  require Logger

  @doc """
  Crea (u overwrite=false, agrega/actualiza) el registro A de `subdominio`
  en la zona de `dominio_base`, apuntando a `ip_destino`.
  """
  def crear_registro_a(dominio_base, subdominio, ip_destino) do
    case MetadataApp.Integraciones.obtener_credencial_por_sistema("hostinger") do
      nil ->
        {:error, "No hay ninguna credencial de Hostinger configurada -- creá una en /sysadmin/credenciales con sistema_externo \"hostinger\"."}

      credencial ->
        url = (credencial.base_url || "https://api.hostinger.com") <> "/api/dns/v1/zones/#{dominio_base}"

        body = %{
          overwrite: false,
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
