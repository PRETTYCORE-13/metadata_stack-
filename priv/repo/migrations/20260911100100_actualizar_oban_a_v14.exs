defmodule MetadataApp.Repo.Migrations.ActualizarObanAV14 do
  use Ecto.Migration

  # La versión de `oban` instalada (2.24.1) exige el esquema v14 -- la
  # migración anterior (20260911100000) quedó en v12 por error (versión
  # equivocada al escribirla). Oban.Migration.up/1 es incremental: solo
  # aplica el diff entre la versión actual de la base y la pedida, no
  # hace falta bajar la v12 primero.
  def up do
    Oban.Migration.up(version: 14)
  end

  def down do
    Oban.Migration.down(version: 12)
  end
end
