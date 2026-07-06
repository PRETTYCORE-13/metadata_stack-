defmodule MetadataApp.Repo.Migrations.CrearPtyCarros20260706171236603 do
  use Ecto.Migration

  def change do
    create table(:pty_carros) do
      add :pty_carro_nombre, :string, size: 30, null: false
      add :pty_carro_tipo, :string, size: 20, null: false

      add :insert_guid, :string, size: 32, null: false
      add :update_guid, :string, size: 32, null: true
      add :delete_guid, :string, size: 32, null: true
    end

    create unique_index(:pty_carros, [:pty_carro_nombre, :pty_carro_tipo], name: :pty_carros_unico_index)
  end
end
