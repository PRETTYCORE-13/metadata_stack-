defmodule MetadataApp.Repo.Migrations.AgregarIconoAMetaSchemaHeader do
  use Ecto.Migration

  # Nombre del ícono de Material Symbols (Google Fonts) a mostrar en el
  # riel colapsado del menú para ese catálogo/carpeta — ej. "inventory_2".
  # Opcional: sin valor, el menú cae de vuelta a su ícono genérico de siempre.
  def change do
    alter table(:meta_schema_header) do
      add :schema_context_icono, :string
    end
  end
end
