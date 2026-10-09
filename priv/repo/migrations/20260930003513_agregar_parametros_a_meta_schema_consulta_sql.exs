defmodule MetadataApp.Repo.Migrations.AgregarParametrosAMetaSchemaConsultaSql do
  use Ecto.Migration

  # SPEC-SYS-2509202601 §11 (uso "servicio": Consulta SQL con parámetros).
  def change do
    alter table(:meta_schema_consulta_sql) do
      # [%{"nombre" =>, "tipo" =>, "obligatorio" =>, "default" =>}, ...].
      # Solo el uso "servicio" los declara; Diccionario y Consulta quedan
      # con [] y se comportan igual que antes.
      add :parametros, :map, null: false, default: fragment("'[]'::jsonb")

      # Máximo de renglones que puede regresar una llamada a un Servicio;
      # si el resultado lo excede, la llamada se rechaza, nunca se recorta.
      add :tope_renglones, :integer, null: false, default: 1000
    end

    create constraint(:meta_schema_consulta_sql, :tope_renglones_rango,
             check: "tope_renglones BETWEEN 1 AND 5000"
           )
  end
end
