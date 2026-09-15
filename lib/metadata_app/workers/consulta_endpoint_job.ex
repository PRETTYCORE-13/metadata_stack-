defmodule MetadataApp.Workers.ConsultaEndpointJob do
  @moduledoc """
  Ejecuta en segundo plano la extracción COMPLETA del resultado de un
  endpoint sobre una Consulta grande (SPEC-SYS-1009202602, R39-R41,
  agregado 2026-09-11) -- nunca materializa todo en memoria de una
  sola vez: reusa la paginación por cursor de `MetaConsultas.ejecutar/6`
  (§5.2.1) en un loop, escribiendo cada lote a un archivo NDJSON a
  medida que llega, en vez de un `Repo.stream/2` aparte -- mismo
  mecanismo ya construido y probado para el modo síncrono, sin
  duplicar la lógica de armar la query.
  """
  use Oban.Worker, queue: :consulta_endpoint_jobs, max_attempts: 1

  alias MetadataApp.ArtefactosJob
  alias MetadataApp.ConsultaEndpoints
  alias MetadataApp.MetaConsultas
  alias MetadataApp.Repo
  alias MetadataApp.MetaSchema.{ConsultaEndpoint, ConsultaEndpointCredencial}

  @tamano_lote 5_000

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"job_id" => job_id, "overrides" => overrides}}) do
    job = ConsultaEndpoints.obtener_job(job_id)
    endpoint = Repo.get!(ConsultaEndpoint, job.meta_schema_consulta_endpoint_id) |> Repo.preload(:consulta)
    credencial = Repo.get!(ConsultaEndpointCredencial, job.meta_schema_consulta_endpoint_credencial_id)

    ConsultaEndpoints.marcar_job_en_curso(job)

    ruta_archivo = ArtefactosJob.ruta_nueva(job.id)

    try do
      cantidad = escribir_lotes(ruta_archivo, endpoint, credencial, overrides)
      ConsultaEndpoints.marcar_job_completado(job, ruta_archivo, cantidad)
      :ok
    rescue
      error ->
        ConsultaEndpoints.marcar_job_fallido(job, Exception.message(error))
        {:error, error}
    end
  end

  defp escribir_lotes(ruta_archivo, endpoint, credencial, overrides) do
    {:ok, archivo} = File.open(ruta_archivo, [:write, :utf8])

    try do
      escribir_lote(archivo, endpoint, credencial, overrides, nil, 0)
    after
      File.close(archivo)
    end
  end

  defp escribir_lote(archivo, endpoint, credencial, overrides, cursor, acumulado) do
    resultado =
      MetaConsultas.ejecutar(
        endpoint.consulta,
        {:empresa_fija, endpoint.empresa_id},
        %{},
        [despues_de_id: cursor, limit: @tamano_lote],
        nil,
        overrides
      )

    Enum.each(resultado.filas, fn fila ->
      linea = fila |> serializar_mapa() |> Map.take(credencial.campos_permitidos) |> Jason.encode!()
      IO.write(archivo, linea <> "\n")
    end)

    nuevo_acumulado = acumulado + length(resultado.filas)

    if length(resultado.filas) == @tamano_lote do
      ultimo_id = resultado.filas |> List.last() |> Map.fetch!(:id)
      escribir_lote(archivo, endpoint, credencial, overrides, ultimo_id, nuevo_acumulado)
    else
      nuevo_acumulado
    end
  end

  defp serializar_mapa(mapa), do: Map.new(mapa, fn {clave, valor} -> {to_string(clave), valor} end)
end
