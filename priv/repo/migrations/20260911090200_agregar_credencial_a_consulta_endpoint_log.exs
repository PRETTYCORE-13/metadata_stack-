defmodule MetadataApp.Repo.Migrations.AgregarCredencialAConsultaEndpointLog do
  use Ecto.Migration

  # Sin FK viva a propósito, mismo criterio que el resto de esta tabla
  # (design.md §1.1/§1.2) -- nil si la llamada nunca llegó a resolver
  # una credencial (401 sin match, 404).
  def change do
    alter table(:meta_schema_consulta_endpoint_log) do
      add :meta_schema_consulta_endpoint_credencial_id, :integer
    end
  end
end
