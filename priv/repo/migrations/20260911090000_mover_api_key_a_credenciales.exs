defmodule MetadataApp.Repo.Migrations.MoverApiKeyACredenciales do
  use Ecto.Migration

  # SPEC-SYS-1009202602, R19.1 (2026-09-11) -- "1 endpoint = 1 key" pasa
  # a "1 endpoint = N credenciales" (design.md §1.2). Sin datos reales
  # en producción todavía (spec recién construida en esta misma
  # sesión) -- se sacan las columnas viejas directo, sin migrar datos.
  def change do
    alter table(:meta_schema_consulta_endpoint) do
      remove :api_key_hash, :string
      remove :api_key_sufijo, :string
    end
  end
end
