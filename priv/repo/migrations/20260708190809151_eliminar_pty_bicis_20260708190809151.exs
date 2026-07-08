defmodule MetadataApp.Repo.Migrations.EliminarPtyBicis20260708190809151 do
  use Ecto.Migration

  def change do
    drop table(:pty_bicis)
  end
end
