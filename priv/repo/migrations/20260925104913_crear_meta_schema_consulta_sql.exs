defmodule MetadataApp.Repo.Migrations.CrearMetaSchemaConsultaSql do
  use Ecto.Migration

  # SPEC-SYS-2509202601 (Consulta SQL, schema_context_type: 4) -- la
  # definición de una Consulta SQL: el SQL tal cual, en qué se usa y qué
  # columnas entrega. La vista de Postgres que se genera a partir del SQL
  # vive en su propia migración `*_vista_pty_sql_*` (gitignoreada, viaja
  # con mix motor.publicar), nunca acá.
  def change do
    create table(:meta_schema_consulta_sql) do
      add :meta_schema_header_id, references(:meta_schema_header), null: false

      # "diccionario" (alimenta combos de campos referencia) | "consulta"
      # (reporte de solo lectura).
      add :uso, :string, null: false, default: "diccionario"

      # nil hasta el primer "Validar y guardar" -- el alta desde BC List
      # crea solo el encabezado.
      add :sql, :text, null: true

      # [%{"nombre" =>, "tipo" =>}, ...] detectadas al guardar el SQL.
      add :columnas, :map, null: false, default: fragment("'[]'::jsonb")

      # NOMBRES de catálogo (no ids: cambian entre ambientes y esto se
      # publica) autorizados a elegir este Diccionario en sus campos.
      add :bcs_autorizados, {:array, :string}, null: false, default: []

      add :insert_guid, :string, size: 32, null: false
      add :update_guid, :string, size: 32, null: true
      add :delete_guid, :string, size: 32, null: true

      timestamps(type: :utc_datetime)
    end

    create unique_index(:meta_schema_consulta_sql, [:meta_schema_header_id])
  end
end
