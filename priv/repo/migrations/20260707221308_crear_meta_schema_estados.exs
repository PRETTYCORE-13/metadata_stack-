defmodule MetadataApp.Repo.Migrations.CrearMetaSchemaEstados do
  use Ecto.Migration

  # Motor de Estados y Transiciones. "catalogo" del spec se resuelve como
  # meta_schema_header_id (FK), no como string suelto: meta_schema_header ya
  # es la fuente de verdad de qué catálogos existen (schema_context_name es
  # el nombre físico de tabla), y meta_schema_detail ya referencia headers
  # por id en vez de por nombre — se sigue esa misma convención acá.
  def change do
    create table(:meta_schema_estados) do
      add :empresa_id, :integer, null: true

      add :meta_schema_header_id, references(:meta_schema_header, on_delete: :delete_all),
        null: false

      add :nombre, :string, size: 100, null: false
      add :es_inicial, :boolean, null: false, default: false
      add :orden, :integer, null: false
      add :color, :string, size: 20, null: true
      add :icono, :string, size: 100, null: true

      add :insert_guid, :string, size: 32, null: false
      add :update_guid, :string, size: 32, null: true
      add :delete_guid, :string, size: 32, null: true
    end

    create unique_index(:meta_schema_estados, [:meta_schema_header_id, :nombre],
             name: :meta_schema_estados_unico_index
           )

    # A lo sumo un estado inicial por catálogo a nivel de base de datos.
    # Que exista AL MENOS uno se valida en la capa de contexto (no es
    # expresable como constraint de Postgres sin un trigger).
    create unique_index(:meta_schema_estados, [:meta_schema_header_id],
             name: :meta_schema_estados_un_inicial_index,
             where: "es_inicial = true"
           )
  end
end
