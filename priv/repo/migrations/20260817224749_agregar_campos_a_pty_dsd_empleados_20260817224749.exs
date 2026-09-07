defmodule MetadataApp.Repo.Migrations.AgregarPtyDsdEmpleadosDsdEmpleadosFuncionAPtyDsdEmpleados20260817224749 do
  use Ecto.Migration

  # Mismo motivo/mismo fix que 20260817201540_crear_pty_dsd_empleados
  # (2026-09-04, SPEC-SYS-0309202601) -- esta columna de todas formas se
  # vuelve a quitar en 20260817224821 (nunca sobrevive al schema final),
  # así que ni siquiera hace falta la FK acá.
  def change do
    alter table(:pty_dsd_empleados) do
      add :pty_dsd_empleados_dsd_empleados_funcion, :bigint, null: true
    end
  end
end
