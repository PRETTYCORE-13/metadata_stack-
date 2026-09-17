defmodule MetadataApp.Repo.Migrations.CorregirTipoPzaprevPzaliqHistorico do
  use Ecto.Migration

  # Bug real (2026-09-17): estos dos campos se crearon como :integer,
  # pero el sistema fuente los manda como decimal (ej. "6.0000") --
  # Postgres/Ecto rechazan el cast de un float a una columna integer.
  # "Piezas" en este contexto no es un conteo entero estricto según el
  # dato real, así que se corrige a decimal (mismo precision/escala que
  # los demás campos numéricos de este catálogo).
  def up do
    alter table(:historico) do
      modify :historico_pzaprev, :decimal, precision: 15, scale: 4
      modify :historico_pzaliq, :decimal, precision: 15, scale: 4
    end
  end

  def down do
    alter table(:historico) do
      modify :historico_pzaprev, :integer
      modify :historico_pzaliq, :integer
    end
  end
end
