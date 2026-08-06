defmodule MetadataApp.Repo.Migrations.AgregarFiltroDefaultFechaAHeader do
  use Ecto.Migration

  def change do
    alter table(:meta_schema_header) do
      add :filtro_default_fecha_modo, :string
      add :filtro_default_fecha_valor, :date
    end
  end
end
