defmodule MetadataApp.Repo.Migrations.BackfillFechaRegistro do
  use Ecto.Migration

  # Le suma "fecha_registro" a TODA tabla de catálogo ya existente (las
  # nuevas ya la traen de fábrica, ver crear_migracion/3 en
  # CatalogoGenerador, y CatalogoGenerador.generar/1 se la agrega sola a
  # cualquier catálogo existente la próxima vez que gen.catalogos lo
  # toque — ver asegurar_fecha_registro/1 ahí). Acá se hace de una sola
  # vez para TODAS, sin esperar a que cada una se vuelva a tocar, y de
  # paso se rellena con la fecha de alta real (desde
  # meta_schema_auditoria, la única fuente que sabe "cuándo se creó" cada
  # fila — los catálogos generados no tienen columna de timestamp
  # propia). Filas sin una entrada de auditoría "alta" que matchee
  # (insertadas por fuera de CatalogoGenerico.crear/2, ej. una migración
  # a mano) quedan en NULL — no hay de dónde sacar esa fecha.
  def up do
    %{rows: filas} =
      repo().query!("""
      SELECT schema_context_name FROM meta_schema_header
      WHERE schema_context_type = 1 AND delete_guid IS NULL
      """)

    for [tabla] <- filas do
      %{rows: [[existe?]]} = repo().query!("SELECT to_regclass($1) IS NOT NULL", ["public.#{tabla}"])

      if existe? do
        execute("ALTER TABLE #{tabla} ADD COLUMN IF NOT EXISTS fecha_registro timestamptz")

        execute("""
        UPDATE #{tabla} AS t
        SET fecha_registro = a.inserted_at
        FROM meta_schema_auditoria a
        WHERE a.bc = '#{tabla}' AND a.operacion = 'alta' AND a.entidad_id = t.id
          AND t.fecha_registro IS NULL
        """)
      end
    end
  end

  def down, do: :ok
end
