defmodule MetadataApp.Repo.Migrations.CrearMetaSchemaUsuarioSesionMovil do
  use Ecto.Migration

  # SPEC-API-0409202601 -- autenticación móvil (Flutter), ver design.md
  # §2. Mismo patrón que meta_schema_usuario_tokens (FK con
  # on_delete: :delete_all, sin guids de soft-delete -- revocar una
  # sesión es un DELETE real, no un flag) pero en tabla aparte: esta
  # necesita etiqueta_dispositivo/ultimo_uso_en para la pantalla de
  # sesiones activas (R7), y su ciclo de vida es distinto (se actualiza
  # en cada refresh, no es de un solo uso).
  def change do
    create table(:meta_schema_usuario_sesion_movil) do
      add :usuario_id, references(:meta_schema_usuario, on_delete: :delete_all), null: false
      add :refresh_token_hash, :binary, null: false
      add :etiqueta_dispositivo, :string
      add :ultimo_uso_en, :utc_datetime

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:meta_schema_usuario_sesion_movil, [:usuario_id])
    create unique_index(:meta_schema_usuario_sesion_movil, [:refresh_token_hash])
  end
end
