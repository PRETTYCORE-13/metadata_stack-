defmodule MetadataApp.Repo.Migrations.AgregarOrdenPorAMetaSchemaConsulta do
  use Ecto.Migration

  def change do
    alter table(:meta_schema_consulta) do
      # Orden de resultados (R1, admin) -- lista de columnas por las que
      # ordenar, en prioridad (la primera manda, después desempata la
      # siguiente): [%{"catalogo" =>, "campo" =>, "direccion" => "asc"|"desc"},
      # ...]. Cualquier campo de `campos` es elegible, visible o no -- a
      # diferencia de "es_parametro" (que sí exige visible), ordenar por
      # una columna no la hace aparecer en la tabla.
      add :orden_por, :map, null: false, default: fragment("'[]'::jsonb")
    end
  end
end
