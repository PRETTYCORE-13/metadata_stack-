defmodule MetadataAppWeb.Api.ConsultaEndpointJobController do
  @moduledoc """
  Ejecución asíncrona del resultado COMPLETO de un endpoint sobre una
  Consulta grande (SPEC-SYS-1009202602, R39-R41, agregado 2026-09-11)
  -- `:crear` encola (202 inmediato), `:mostrar` consulta estado y, si
  está completado, sirve el archivo NDJSON por streaming (nunca lo
  carga entero en memoria). Mismo esquema de autenticación por
  credencial que `ConsultaEndpointController` (Bearer, R20-R21).
  """
  use MetadataAppWeb, :controller

  alias MetadataApp.ConsultaEndpoints

  def crear(conn, %{"ruta" => ruta} = params) do
    case ConsultaEndpoints.obtener_publicado_por_ruta(ruta) do
      nil ->
        conn |> put_status(:not_found) |> json(%{"error" => "Endpoint no encontrado"})

      endpoint ->
        autenticar_y_crear(conn, endpoint, params)
    end
  end

  defp autenticar_y_crear(conn, endpoint, params) do
    case api_key_presentada(conn) do
      :error ->
        conn |> put_status(:unauthorized) |> json(%{"error" => "Falta Authorization: Bearer <api_key>"})

      {:ok, key} ->
        case ConsultaEndpoints.resolver_credencial(endpoint.id, key) do
          nil ->
            conn |> put_status(:unauthorized) |> json(%{"error" => "API key inválida"})

          credencial ->
            valores_externos = Map.drop(params, ["ruta"])

            case ConsultaEndpoints.construir_overrides(endpoint.consulta, endpoint, valores_externos) do
              {:error, {:parametros_faltantes, claves}} ->
                mensaje = "Faltan parámetros obligatorios: #{Enum.join(claves, ", ")}"
                conn |> put_status(:bad_request) |> json(%{"error" => mensaje})

              {:ok, overrides} ->
                {:ok, job} = ConsultaEndpoints.crear_job(endpoint, credencial, overrides)
                conn |> put_status(:accepted) |> json(%{"job_id" => job.id, "estado" => job.estado})
            end
        end
    end
  end

  def mostrar(conn, %{"ruta" => ruta, "job_id" => job_id}) do
    case ConsultaEndpoints.obtener_publicado_por_ruta(ruta) do
      nil ->
        conn |> put_status(:not_found) |> json(%{"error" => "Endpoint no encontrado"})

      endpoint ->
        autenticar_y_mostrar(conn, endpoint, job_id)
    end
  end

  defp autenticar_y_mostrar(conn, endpoint, job_id) do
    case api_key_presentada(conn) do
      :error ->
        conn |> put_status(:unauthorized) |> json(%{"error" => "Falta Authorization: Bearer <api_key>"})

      {:ok, key} ->
        case ConsultaEndpoints.resolver_credencial(endpoint.id, key) do
          nil -> conn |> put_status(:unauthorized) |> json(%{"error" => "API key inválida"})
          _credencial -> responder_estado_job(conn, endpoint, job_id)
        end
    end
  end

  defp responder_estado_job(conn, endpoint, job_id) do
    with {id, ""} <- Integer.parse(job_id),
         %{meta_schema_consulta_endpoint_id: endpoint_id} = job <- ConsultaEndpoints.obtener_job(id),
         true <- endpoint_id == endpoint.id do
      case job.estado do
        "completado" ->
          conn
          |> put_resp_header("content-type", "application/x-ndjson")
          |> send_file(200, job.archivo_resultado)

        "fallido" ->
          conn |> put_status(:ok) |> json(%{"job_id" => job.id, "estado" => job.estado, "error" => job.error})

        _pendiente_o_en_curso ->
          conn |> put_status(:ok) |> json(%{"job_id" => job.id, "estado" => job.estado})
      end
    else
      _ -> conn |> put_status(:not_found) |> json(%{"error" => "Job no encontrado"})
    end
  end

  defp api_key_presentada(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> key] when key != "" -> {:ok, key}
      _ -> :error
    end
  end
end
