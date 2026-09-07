defmodule MetadataApp.Repo.Migrations.CrearPtyDsdEmpleados20260817201540 do
  use Ecto.Migration

  # `references(:pty_dsd_empleados_funcion)` original quitada (2026-09-04,
  # SPEC-SYS-0309202601, auditoría de replay desde cero): esa tabla vive
  # en el bloque de migraciones con timestamp viejo de 17 dígitos
  # (milisegundos, previo al fix de `CatalogoGenerador.timestamp_utc/0`)
  # -- Ecto ordena por VALOR NUMÉRICO, y un número de 17 dígitos es más
  # grande que cualquiera de 14, así que en un replay desde cero todo ese
  # bloque corre DESPUÉS de esta migración aunque su fecha real (ago 11-12)
  # sea anterior (ago 17). Un sistema YA migrado no se ve afectado -- Ecto
  # marca por versión, no por contenido, y ahí la tabla ya existía cuando
  # esto corrió de verdad. Columna llana sin FK a nivel base -- la
  # integridad referencial la sigue garantizando Ecto a nivel aplicación.
  def change do
    create table(:pty_dsd_empleados) do
      add :pty_dsd_empleados_nombre, :string, size: 100, null: false
      add :pty_dsd_empleados_fecha_alta, :date, null: false
      add :pty_dsd_empleados_fecha_baja, :date, null: false
      add :pty_dsd_empleados_dsd_empleados_funcion, :bigint, null: false

      add :insert_guid, :string, size: 32, null: false
      add :update_guid, :string, size: 32, null: true
      add :delete_guid, :string, size: 32, null: true

      add :estado_id, references(:meta_schema_estados), null: true

      add :fecha_registro, :utc_datetime, null: true

      add :trn, :string, size: 23, null: true
      add :ulid, :string, size: 26, null: true

      add :branch_id, :integer, null: true
      add :sales_unit_id, :integer, null: true
      add :inventory_id, :integer, null: true
      add :creado_por_id, :integer, null: true

    end

    create unique_index(:pty_dsd_empleados, [:pty_dsd_empleados_nombre, :pty_dsd_empleados_fecha_alta, :pty_dsd_empleados_fecha_baja, :pty_dsd_empleados_dsd_empleados_funcion], name: :pty_dsd_empleados_unico_index)
    create unique_index(:pty_dsd_empleados, [:trn], name: :pty_dsd_empleados_trn_unico_index)
    create unique_index(:pty_dsd_empleados, [:ulid], name: :pty_dsd_empleados_ulid_unico_index)

  end
end
