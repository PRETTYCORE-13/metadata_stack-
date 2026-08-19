defmodule MetadataApp.Repo.Migrations.AgregarPropositoAPlantillas do
  use Ecto.Migration

  # "Multi vista" hasta ahora era solo "varias plantillas alternativas para
  # la MISMA pantalla interactiva" — proposito distingue eso ("vista", el
  # default) de una plantilla pensada para imprimir ("impresion", ver
  # FichaLive ?imprimir=1). El índice único de "publicada" se re-escopea a
  # (header, proposito): antes solo dejaba UNA plantilla publicada por
  # catálogo sin importar el propósito, lo que haría que publicar la de
  # impresión despublicara la de pantalla (y viceversa).
  def change do
    alter table(:meta_schema_plantillas) do
      add :proposito, :string, size: 20, null: false, default: "vista"
    end

    drop unique_index(:meta_schema_plantillas, [:meta_schema_header_id],
           where: "estado = 'publicada'",
           name: :meta_schema_plantillas_publicada_unica_index
         )

    create unique_index(:meta_schema_plantillas, [:meta_schema_header_id, :proposito],
             where: "estado = 'publicada'",
             name: :meta_schema_plantillas_publicada_unica_index
           )
  end
end
