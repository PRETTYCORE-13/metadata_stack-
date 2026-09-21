defmodule MetadataApp.Repo.Migrations.CrearValRollbackTest2 do
  use Ecto.Migration

  @moduledoc """
  Segunda migración descartable -- verificación final del rollback de BD
  ya corregido (SPEC-SYS-1809202603 Grupo H, tarea 38, segunda vuelta).
  Se revierte y se borra del repo en cuanto la verificación termina.
  """

  def change do
    create table(:_val_rollback_test2) do
      add :nombre, :string
      timestamps()
    end
  end
end
