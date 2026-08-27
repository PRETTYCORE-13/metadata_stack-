defmodule MetadataApp.Repo.Migrations.AgregarFiltroFechaDefaultAMetaSchemaConsulta do
  use Ecto.Migration

  # A diferencia de un catálogo normal (el filtro de fecha por default
  # SIEMPRE es contra "fecha_registro", columna fija -- ver
  # CatalogoLive.filtros_por_default/1), una Consulta puede tener varios
  # campos tipo fecha, incluso con el MISMO nombre repetido en distintas
  # tablas unidas (dos "fecha_registro" de dos catálogos distintos, caso
  # real ya visto en dev) -- hace falta guardar explícitamente CUÁL
  # campo (catalogo + campo, no solo el nombre) es el destino, además
  # del modo/valores que ya vive en meta_schema_header
  # (filtro_default_fecha_modo/valor/valor_hasta, reusados tal cual).
  def change do
    alter table(:meta_schema_consulta) do
      add :filtro_fecha_catalogo, :string, null: true
      add :filtro_fecha_campo, :string, null: true
    end
  end
end
