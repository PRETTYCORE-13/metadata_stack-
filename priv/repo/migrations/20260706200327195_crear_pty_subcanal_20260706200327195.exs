defmodule MetadataApp.Repo.Migrations.CrearPtySubcanal20260706200327195 do
  use Ecto.Migration

  def change do
    create table(:pty_subcanal) do
      add :subcanal_nombre, :string, size: 150, null: false
      add :id_canal, references(:pty_canal), null: false

      add :insert_guid, :string, size: 32, null: false
      add :update_guid, :string, size: 32, null: true
      add :delete_guid, :string, size: 32, null: true
    end

    create unique_index(:pty_subcanal, [:subcanal_nombre, :id_canal], name: :pty_subcanal_unico_index)
  end
end
