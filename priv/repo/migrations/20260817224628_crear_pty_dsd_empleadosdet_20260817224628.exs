defmodule MetadataApp.Repo.Migrations.CrearPtyDsdEmpleadosdet20260817224628 do
  use Ecto.Migration

  # Mismo motivo/mismo fix que 20260817201540_crear_pty_dsd_empleados
  # (2026-09-04, SPEC-SYS-0309202601): `pty_dsd_empleados_funcion` vive en
  # el bloque de timestamp viejo de 17 dígitos, que en un replay desde
  # cero corre DESPUÉS de esta migración de 14 dígitos por valor numérico,
  # sin importar la fecha real.
  def change do
    create table(:pty_dsd_empleadosdet) do
      add :pty_dsd_empleadosdet_dsd_empleados_funcion, :bigint, null: false

      add :insert_guid, :string, size: 32, null: false
      add :update_guid, :string, size: 32, null: true
      add :delete_guid, :string, size: 32, null: true

      add :estado_id, references(:meta_schema_estados), null: true

      add :fecha_registro, :utc_datetime, null: true

      add :encabezado_id, references(:pty_dsd_empleados), null: false
      add :renglon_id, :integer, null: false

      add :branch_id, :integer, null: true
      add :sales_unit_id, :integer, null: true
      add :inventory_id, :integer, null: true
      add :creado_por_id, :integer, null: true

    end

    create unique_index(:pty_dsd_empleadosdet, [:encabezado_id, :pty_dsd_empleadosdet_dsd_empleados_funcion], name: :pty_dsd_empleadosdet_unico_index)
    create unique_index(:pty_dsd_empleadosdet, [:encabezado_id, :renglon_id], name: :pty_dsd_empleadosdet_encabezado_renglon_unico_index)

  end
end
