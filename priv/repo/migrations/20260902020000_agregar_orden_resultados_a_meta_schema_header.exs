defmodule MetadataApp.Repo.Migrations.AgregarOrdenResultadosAMetaSchemaHeader do
  use Ecto.Migration

  def change do
    alter table(:meta_schema_header) do
      # "Orden de resultados" del Get Config del BC Motor (mismo patrón que
      # meta_schema_consulta.orden_por, ver esa migración) -- lista de
      # columnas por las que CatalogoLive ordena por default, en
      # prioridad: [%{"campo" =>, "direccion" => "asc"|"desc"}, ...].
      # Sin "catalogo" (a diferencia de Consulta): un BC normal es una
      # sola tabla, no hace falta desambiguar.
      add :orden_resultados, :map, null: false, default: fragment("'[]'::jsonb")
    end
  end
end
