defmodule MetadataApp.Repo.Migrations.CrearMetaSchemaTransicionReglas do
  use Ecto.Migration

  # Nota: el spec (sección 3.3) no lista "transaccional" como columna, pero
  # el Paso 5a del ciclo de ejecución (sección 4) exige distinguir postcondiciones
  # transaccionales de las de cortesía por regla-instancia — sin una columna acá
  # no hay dónde guardar esa marca. Se agrega para cerrar ese hueco del spec.
  def change do
    create table(:meta_schema_transicion_reglas) do
      add :transicion_id, references(:meta_schema_transiciones, on_delete: :delete_all),
        null: false

      add :tipo, :string, size: 10, null: false
      add :regla, :string, size: 100, null: false
      add :params, :map, null: false, default: %{}
      add :orden, :integer, null: false, default: 0
      add :transaccional, :boolean, null: false, default: true

      add :insert_guid, :string, size: 32, null: false
      add :update_guid, :string, size: 32, null: true
      add :delete_guid, :string, size: 32, null: true
    end

    create index(:meta_schema_transicion_reglas, [:transicion_id, :tipo, :orden])
  end
end
