defmodule MetadataApp.Repo.Migrations.QuitarPzaliqDeHistorico20260915193451 do
  use Ecto.Migration

  def change do
    alter table(:historico) do
      remove :pzaliq
    end
  end
end
