defmodule MetadataApp.ArtefactosJob do
  @moduledoc """
  Archivo de resultado de un Job de endpoint (SPEC-SYS-1009202602,
  R39-R41, agregado 2026-09-11) -- NDJSON (una fila JSON por línea) en
  disco local, NUNCA en una columna de la base (un `jsonb` con millones
  de filas sería el mismo problema de memoria al leerlo después).

  Directorio temporal del sistema, no `priv/` -- no es un asset que
  deba viajar con el release, es un archivo de trabajo transitorio por
  Job.
  """

  @directorio Path.join(System.tmp_dir!(), "metadata_app_jobs_endpoint")

  def directorio, do: @directorio

  def ruta_nueva(job_id) do
    File.mkdir_p!(@directorio)
    Path.join(@directorio, "job_#{job_id}_#{Ecto.UUID.generate()}.ndjson")
  end
end
