defmodule MetadataApp.Repo.Migrations.QuitarFiltroDefaultFechaDeHeader do
  use Ecto.Migration

  # SPEC-SYS-1109202606 §5/§8 -- "Filtros por default" (Get Config) se
  # eliminó a pedido explícito del usuario (2026-09-11): ningún catálogo
  # real lo tenía configurado (verificado en vivo, 0 filas), y
  # SPEC-SYS-0209202601 (Parámetros) ya cubre la misma necesidad de forma
  # más flexible. Ver header.ex para el detalle completo.
  def change do
    alter table(:meta_schema_header) do
      remove :filtro_default_fecha_modo, :string
      remove :filtro_default_fecha_valor, :date
      remove :filtro_default_fecha_valor_hasta, :date
    end
  end
end
