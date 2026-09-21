defmodule MetadataApp.Repo.Migrations.CrearValRollbackTest do
  use Ecto.Migration

  @moduledoc """
  Migración descartable para verificar en real el rollback automático de
  base de datos (SPEC-SYS-1809202603 Grupo H, tarea 38) -- tabla vacía
  nueva, clasificable "automática" por SeguridadMigracion. Se revierte y
  se borra del repo en cuanto la verificación termina.
  """

  def change do
    create table(:_val_rollback_test) do
      add :nombre, :string
      timestamps()
    end
  end
end
