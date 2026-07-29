defmodule MetadataApp.Repo.Migrations.AgregarOrdenAMetaSchemaHeader do
  use Ecto.Migration

  # Orden manual (drag-and-drop) de carpetas raíz — ver "Editar vista" en
  # BcListLive. nil = todavía sin ordenar a mano, cae al orden alfabético
  # de siempre (MetaSchemaContext.mapa_a_lista_ordenada/1).
  def change do
    alter table(:meta_schema_header) do
      add :orden, :integer
    end
  end
end
