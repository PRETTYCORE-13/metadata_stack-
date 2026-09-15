defmodule MetadataApp.Repo.Migrations.QuitarPedctedDesc1DeHistorico20260915193152 do
  use Ecto.Migration

  def change do
    alter table(:historico) do
      remove :pedcted_desc1
    end
  end
end
