defmodule MetadataApp.Repo.Migrations.AgregarFiltroDefaultFechaHastaAHeader do
  use Ecto.Migration

  def change do
    alter table(:meta_schema_header) do
      add :filtro_default_fecha_valor_hasta, :date
    end
  end
end
