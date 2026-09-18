defmodule MetadataApp.Repo.Migrations.CrearVerificacionRollbackSpecH do
  use Ecto.Migration

  # TEMPORAL -- verificación real de punta a punta de Grupo H
  # (SPEC-SYS-1809202603, rollback automático de base de datos). Tabla
  # vacía, sin ningún uso real -- se crea, se propaga a "testing", se
  # revierte desde la pantalla /sysadmin/propagacion, y este commit se
  # revierte de main apenas termina la verificación.
  def change do
    create table(:verificacion_rollback_spec_h) do
      add :nota, :string
    end
  end
end
