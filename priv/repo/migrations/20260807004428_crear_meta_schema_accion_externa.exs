defmodule MetadataApp.Repo.Migrations.CrearMetaSchemaAccionExterna do
  use Ecto.Migration

  def change do
    create table(:meta_schema_accion_externa) do
      # nilable a propósito -- una acción puede vivir "suelta" (standalone)
      # o atada a un catálogo/consulta puntual (botón en su Ficha 360°).
      # nilify_all en vez de delete_all: borrar el catálogo no debería
      # borrar en cascada la configuración de la integración, solo
      # dejarla sin catálogo asociado.
      add :meta_schema_header_id, references(:meta_schema_header, on_delete: :nilify_all)
      add :credencial_id, references(:meta_schema_credencial, on_delete: :restrict), null: false

      add :nombre, :string, null: false
      add :etiqueta, :string
      add :metodo, :string, null: false
      add :url_template, :string, null: false
      add :headers_template, :map, default: %{}
      add :body_template, :text
      add :confirmar_antes, :boolean, null: false, default: false
      add :orden, :integer, default: 0

      add :insert_guid, :string
      add :update_guid, :string
      add :delete_guid, :string

      timestamps(type: :utc_datetime)
    end

    create index(:meta_schema_accion_externa, [:meta_schema_header_id])
    create index(:meta_schema_accion_externa, [:credencial_id])
    create index(:meta_schema_accion_externa, [:delete_guid])
  end
end
