defmodule MetadataApp.Repo.Migrations.CrearMetaSchemaAuditoria do
  use Ecto.Migration

  # Log de auditoría de DATOS (roadmap #6 — distinto del #13, que audita la
  # DEFINICIÓN de un BC, no sus registros). Particionada por RANGE(inserted_at)
  # desde el día uno: es gratis hacerlo ahora y carísimo agregarlo después
  # sobre una tabla con millones de filas. Hoy vive TODO en una sola
  # partición DEFAULT (mismo costo/performance que una tabla plana sin
  # particionar) — el día que haga falta archivar, se crean particiones por
  # fecha reales (`CREATE TABLE ... PARTITION OF ... FOR VALUES FROM ... TO
  # ...`) y Postgres mueve solo las filas que correspondan fuera del
  # DEFAULT, sin tocar ni una línea de código de la app. Los índices creados
  # sobre la tabla padre se propagan solos a cualquier partición futura.
  #
  # Sin `insert_guid`/`update_guid`/`delete_guid` como el resto de
  # `meta_schema_*`: esto es un log append-only, nunca se edita ni se borra
  # una fila de acá — `inserted_at` ES el dato de auditoría (y la columna
  # de partición), no metadata de Ecto.
  #
  # `ip`/`user_agent` son a propósito los únicos datos de "desde dónde":
  # MAC address y nombre de PC NO son capturables desde un request
  # HTTP/LiveView — ningún browser los expone al servidor.
  def up do
    execute """
    CREATE TABLE meta_schema_auditoria (
      id bigserial NOT NULL,
      bc varchar(100) NOT NULL,
      operacion varchar(50) NOT NULL,
      guid varchar(32) NOT NULL,
      trn varchar(50),
      entidad_id bigint NOT NULL,
      datos jsonb NOT NULL,
      usuario_id bigint,
      usuario_email varchar(255),
      empresa_id bigint,
      ip varchar(45),
      user_agent varchar(255),
      inserted_at timestamp(0) NOT NULL DEFAULT now(),
      PRIMARY KEY (id, inserted_at)
    ) PARTITION BY RANGE (inserted_at)
    """

    execute "CREATE TABLE meta_schema_auditoria_default PARTITION OF meta_schema_auditoria DEFAULT"

    execute "CREATE INDEX meta_schema_auditoria_bc_entidad_idx ON meta_schema_auditoria (bc, entidad_id)"
    execute "CREATE INDEX meta_schema_auditoria_empresa_fecha_idx ON meta_schema_auditoria (empresa_id, inserted_at)"
  end

  def down do
    execute "DROP TABLE IF EXISTS meta_schema_auditoria CASCADE"
  end
end
