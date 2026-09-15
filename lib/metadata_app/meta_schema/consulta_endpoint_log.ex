defmodule MetadataApp.MetaSchema.ConsultaEndpointLog do
  use Ecto.Schema
  import Ecto.Changeset

  # Auditoría de acceso HTTP de un endpoint publicado (R33/R34) --
  # deliberadamente separada de MetaAuditoria.registrar/6, cuya forma
  # es para alta/edición/baja de un registro de negocio, no para
  # accesos HTTP. NUNCA tiene columna para la API key ni para los
  # valores de los parámetros de la llamada.
  schema "meta_schema_consulta_endpoint_log" do
    field :meta_schema_consulta_endpoint_id, :id
    # Sin FK viva a propósito (2026-09-11, R19.1) -- nil si la llamada
    # nunca llegó a resolver una credencial (401 sin match, 404).
    field :meta_schema_consulta_endpoint_credencial_id, :id
    field :fecha_hora, :utc_datetime_usec
    field :empresa_id, :id
    field :ip, :string
    field :metodo, :string
    field :resultado_http, :integer
    field :duracion_ms, :integer
    field :cantidad_registros, :integer

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @requeridos [
    :meta_schema_consulta_endpoint_id,
    :fecha_hora,
    :empresa_id,
    :metodo,
    :resultado_http,
    :duracion_ms
  ]

  def changeset(log, attrs) do
    log
    |> cast(attrs, @requeridos ++ [:ip, :cantidad_registros, :meta_schema_consulta_endpoint_credencial_id])
    |> validate_required(@requeridos)
  end
end
