defmodule MetadataApp.MetaSchema.ConsultaEndpointJob do
  use Ecto.Schema
  import Ecto.Changeset

  # Estado de una extracción asíncrona del resultado COMPLETO de un
  # endpoint (SPEC-SYS-1009202602, R39-R41, agregado 2026-09-11) --
  # `estado`: "pendiente" (encolado) | "en_curso" (el worker lo tomó) |
  # "completado" (archivo_resultado listo) | "fallido" (ver `error`).
  # Sin FK vivas a propósito, mismo criterio que ConsultaEndpointLog --
  # sobrevive aunque el endpoint/credencial cambien después.
  schema "meta_schema_consulta_endpoint_job" do
    field :meta_schema_consulta_endpoint_id, :id
    field :meta_schema_consulta_endpoint_credencial_id, :id
    field :oban_job_id, :integer
    field :estado, :string, default: "pendiente"
    field :archivo_resultado, :string
    field :cantidad_registros, :integer
    field :error, :string

    timestamps(type: :utc_datetime)
  end

  @estados ["pendiente", "en_curso", "completado", "fallido"]
  @requeridos [:meta_schema_consulta_endpoint_id, :meta_schema_consulta_endpoint_credencial_id]

  def changeset(job, attrs) do
    job
    |> cast(attrs, @requeridos ++ [:oban_job_id, :estado, :archivo_resultado, :cantidad_registros, :error])
    |> validate_required(@requeridos)
    |> validate_inclusion(:estado, @estados)
  end
end
