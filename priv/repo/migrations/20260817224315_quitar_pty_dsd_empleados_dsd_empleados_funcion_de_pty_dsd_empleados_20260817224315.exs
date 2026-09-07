defmodule MetadataApp.Repo.Migrations.QuitarPtyDsdEmpleadosDsdEmpleadosFuncionDePtyDsdEmpleados20260817224315 do
  use Ecto.Migration

  def change do
    alter table(:pty_dsd_empleados) do
      remove :pty_dsd_empleados_dsd_empleados_funcion
    end
  end
end
