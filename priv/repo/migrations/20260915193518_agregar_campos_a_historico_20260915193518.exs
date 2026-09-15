defmodule MetadataApp.Repo.Migrations.AgregarHistoricoPzaliqAHistorico20260915193518 do
  use Ecto.Migration

  def change do
    alter table(:historico) do
      add :historico_pzaliq, :decimal, null: true
    end
  end
end
