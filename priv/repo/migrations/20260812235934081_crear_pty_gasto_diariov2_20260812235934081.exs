defmodule MetadataApp.Repo.Migrations.CrearPtyGastoDiariov220260812235934081 do
  use Ecto.Migration

  def change do
    create table(:pty_gasto_diariov2) do
      add :pty_gasto_diariov2_descripcion, :string, size: 25, null: false

      add :insert_guid, :string, size: 32, null: false
      add :update_guid, :string, size: 32, null: true
      add :delete_guid, :string, size: 32, null: true

      add :estado_id, references(:meta_schema_estados), null: true

      add :trn, :string, size: 23, null: true
      add :ulid, :string, size: 26, null: true

      add :branch_id, :integer, null: true
      add :sales_unit_id, :integer, null: true
      add :inventory_id, :integer, null: true
      add :creado_por_id, :integer, null: true

      # Agregado acá (2026-09-04, auditoría de replay desde cero) --
      # originalmente venía de una migración de 14 dígitos posterior
      # (20260903013358), que en un replay desde cero corre ANTES que
      # esta (17 dígitos, ver el comentario ahí) -- la tabla todavía no
      # existiría. Esta migración ya está aplicada en cualquier sistema
      # real, así que agregar la columna acá no le afecta.
      add :pty_gasto_diariov2_valor_pagado, :decimal, null: true

    end

    create unique_index(:pty_gasto_diariov2, [:pty_gasto_diariov2_descripcion], name: :pty_gasto_diariov2_unico_index)
    create unique_index(:pty_gasto_diariov2, [:trn], name: :pty_gasto_diariov2_trn_unico_index)
    create unique_index(:pty_gasto_diariov2, [:ulid], name: :pty_gasto_diariov2_ulid_unico_index)

  end
end
