defmodule MetadataApp.Repo.Migrations.AgregarConsultaSqlAConsultaEndpoint do
  use Ecto.Migration

  # SPEC-SYS-2509202601 §11.6 (D6): un Endpoint cuelga de una Consulta
  # Ecto O de un Servicio (Consulta SQL de uso "servicio"), nunca de los
  # dos ni de ninguno.
  def change do
    execute(
      "ALTER TABLE meta_schema_consulta_endpoint ALTER COLUMN meta_schema_consulta_id DROP NOT NULL",
      "ALTER TABLE meta_schema_consulta_endpoint ALTER COLUMN meta_schema_consulta_id SET NOT NULL"
    )

    alter table(:meta_schema_consulta_endpoint) do
      # :restrict y no :delete_all: un Servicio con Endpoint no se elimina
      # (R55); la plataforma lo rechaza antes con un mensaje claro.
      add :meta_schema_consulta_sql_id,
          references(:meta_schema_consulta_sql, on_delete: :restrict), null: true
    end

    # Como máximo un Endpoint por Servicio, igual que por Consulta.
    create unique_index(:meta_schema_consulta_endpoint, [:meta_schema_consulta_sql_id])

    create constraint(:meta_schema_consulta_endpoint, :origen_unico,
             check: "(meta_schema_consulta_id IS NULL) <> (meta_schema_consulta_sql_id IS NULL)"
           )
  end
end
