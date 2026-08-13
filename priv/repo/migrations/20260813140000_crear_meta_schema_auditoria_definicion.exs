defmodule MetadataApp.Repo.Migrations.CrearMetaSchemaAuditoriaDefinicion do
  use Ecto.Migration

  # Roadmap #13 — log de quién crea/modifica/borra la DEFINICIÓN de un
  # catálogo (schema_context_name), distinto del #6 (meta_schema_auditoria,
  # que es de DATOS/registros). Sin partición: a diferencia de la
  # auditoría de datos, esto es de bajísimo volumen (un catálogo se borra
  # o se le quita un campo muy de vez en cuando, no por cada alta de un
  # registro de negocio).
  def up do
    create table(:meta_schema_auditoria_definicion) do
      add :schema_context_name, :string, size: 100, null: false
      add :operacion, :string, size: 50, null: false
      add :detalle, :map, null: false
      add :usuario_id, :bigint
      add :usuario_email, :string, size: 255
      add :empresa_id, :bigint
      add :ip, :string, size: 45
      add :user_agent, :string, size: 255

      timestamps(updated_at: false, type: :utc_datetime)
    end

    create index(:meta_schema_auditoria_definicion, [:schema_context_name])
  end

  def down do
    drop table(:meta_schema_auditoria_definicion)
  end
end
