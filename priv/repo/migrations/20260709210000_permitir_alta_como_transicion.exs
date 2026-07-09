defmodule MetadataApp.Repo.Migrations.PermitirAltaComoTransicion do
  use Ecto.Migration

  # Modela el "alta" (creación de un registro nuevo) como una transición más,
  # con estado_origen_id = NULL representando "todavía no existe". Antes
  # CatalogoGenerico.crear/2 era un insert directo que nunca pasaba por las
  # reglas del motor (pre/post) — con esto, un catálogo puede definir una
  # transición accion="alta" con estado_origen_id nil y CatalogoGenerico.crear/2
  # la usa automáticamente (ver StateEngine.transicion_alta/1 y dar_de_alta/4).
  # Catálogos que nunca definen esa transición (ej. pty_clientes hoy) siguen
  # con el insert directo de siempre — cambio 100% opt-in, no rompe nada.
  def change do
    execute(
      "ALTER TABLE meta_schema_transiciones ALTER COLUMN estado_origen_id DROP NOT NULL",
      "ALTER TABLE meta_schema_transiciones ALTER COLUMN estado_origen_id SET NOT NULL"
    )

    execute(
      "ALTER TABLE meta_schema_transicion_eventos ALTER COLUMN estado_origen_id DROP NOT NULL",
      "ALTER TABLE meta_schema_transicion_eventos ALTER COLUMN estado_origen_id SET NOT NULL"
    )

    # Sin esto, Postgres permitiría N transiciones "alta" distintas con el
    # mismo accion para el mismo header (un índice único normal no considera
    # colisión entre NULLs) — un catálogo solo puede tener una forma de nacer
    # por accion.
    create unique_index(
             :meta_schema_transiciones,
             [:empresa_id, :meta_schema_header_id, :accion],
             name: :meta_schema_transiciones_alta_unico_index,
             where: "estado_origen_id IS NULL"
           )
  end
end
