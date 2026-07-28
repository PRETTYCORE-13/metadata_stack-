defmodule MetadataApp.Repo.Migrations.CrearMetaSchemaPlantillas do
  use Ecto.Migration

  # Constructor de plantillas (MVP): una plantilla es un árbol de
  # componentes (sección/campo/divisor/tabla) que gobierna cómo se ve el
  # tab "Datos" de la Ficha 360° de un catálogo — ver FichaLive. Un
  # catálogo sin ninguna plantilla publicada sigue viéndose exactamente
  # como hoy (lista plana de campos), así que esto es 100% aditivo.
  def change do
    create table(:meta_schema_plantillas) do
      add :meta_schema_header_id, references(:meta_schema_header), null: false
      add :nombre, :string, size: 100, null: false
      add :descripcion, :string, size: 255
      add :estado, :string, size: 20, null: false, default: "borrador"
      add :definicion, :map, null: false, default: %{"tipo" => "raiz", "hijos" => []}

      add :insert_guid, :string, size: 32, null: false
      add :update_guid, :string, size: 32, null: true
      add :delete_guid, :string, size: 32, null: true
    end

    create index(:meta_schema_plantillas, [:meta_schema_header_id])

    # Nunca 2 plantillas publicadas del mismo catálogo a la vez — a nivel
    # DB, no solo de aplicación (mismo criterio que ya usan los índices
    # únicos de meta_schema_detail/meta_schema_header).
    create unique_index(:meta_schema_plantillas, [:meta_schema_header_id],
             where: "estado = 'publicada'",
             name: :meta_schema_plantillas_publicada_unica_index
           )
  end
end
