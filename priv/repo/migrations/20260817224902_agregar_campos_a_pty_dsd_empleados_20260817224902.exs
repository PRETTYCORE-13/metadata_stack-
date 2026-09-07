defmodule MetadataApp.Repo.Migrations.AgregarPtyDsdEmpleadosDsdEmpleadosdetAPtyDsdEmpleados20260817224902 do
  use Ecto.Migration

  def change do
    alter table(:pty_dsd_empleados) do
      add :pty_dsd_empleados_dsd_empleadosdet, references(:pty_dsd_empleadosdet), null: true
    end
  end
end
