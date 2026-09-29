defmodule MetadataApp.Repo.Migrations.AgregarPrefijoDirectorioAMetaSchemaHeader do
  use Ecto.Migration

  # Prefijo de directorio (SPEC-SYS-2909202601): abreviatura de 1 a 5
  # letras/dígitos de una carpeta (schema_context_type 2), ej. "CH" para
  # Capital Humano. Nombre explícito, no "prefijo" a secas: el prefijo
  # propio de un BC es otro atributo, de otra spec, en esta misma tabla.
  # Único entre headers vivos: una carpeta dada de baja libera el suyo.
  def change do
    alter table(:meta_schema_header) do
      add :prefijo_directorio, :string, size: 5
    end

    create unique_index(:meta_schema_header, [:prefijo_directorio],
             where: "prefijo_directorio IS NOT NULL AND delete_guid IS NULL",
             name: :meta_schema_header_prefijo_directorio_unico_index
           )
  end
end
