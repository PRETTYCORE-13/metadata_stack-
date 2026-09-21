defmodule MetadataApp.Repo.Migrations.CrearValRollbackTest3 do
  use Ecto.Migration

  @moduledoc """
  Tercera migración descartable -- verificación real final de Grupo H
  (SPEC-SYS-1809202603, tarea 38) ahora que `testing` quedó destrabada
  (`docs/roadmap.md` #17). Se revierte y se borra del repo en cuanto la
  verificación termina.
  """

  def change do
    create table(:_val_rollback_test3) do
      add :nombre, :string
      timestamps()
    end
  end
end
