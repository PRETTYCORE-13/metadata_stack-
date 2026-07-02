defmodule MetadataApp.Repo.Migrations.AlterarCanalFactor1ADecimal do
  use Ecto.Migration

  def up do
    execute "ALTER TABLE pty_canales ALTER COLUMN canal_factor1 TYPE numeric USING canal_factor1::numeric"
  end

  def down do
    execute "ALTER TABLE pty_canales ALTER COLUMN canal_factor1 TYPE varchar(255) USING canal_factor1::varchar"
  end
end
