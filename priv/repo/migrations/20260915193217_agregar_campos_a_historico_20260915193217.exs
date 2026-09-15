defmodule MetadataApp.Repo.Migrations.AgregarHistoricoPedctedDesc1AHistorico20260915193217 do
  use Ecto.Migration

  def change do
    alter table(:historico) do
      add :historico_pedcted_desc1, :decimal, null: true
    end
  end
end
