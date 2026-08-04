defmodule MetadataApp.Repo.Migrations.CrearMetaSchemaEstadoDetallePermiso do
  use Ecto.Migration

  # Permisos de INSERTAR/ACTUALIZAR/BORRAR renglones de un catálogo detalle,
  # por ESTADO y por TABLA DETALLE (no por rol, no por transición) — capa
  # nueva e independiente del permiso RBAC de transición del encabezado, que
  # sigue intacto. Deny-by-default para cualquier combinación sin fila (ver
  # MetaEstadosAdmin.permiso_detalle/2) — por eso el backfill de abajo: sin
  # él, todo catálogo maestro-detalle que ya funciona hoy dejaría de poder
  # insertar/actualizar/borrar renglones apenas se despliegue esto.
  def up do
    create table(:meta_schema_estado_detalle_permiso) do
      add :empresa_id, :integer, null: true

      add :meta_schema_estado_id, references(:meta_schema_estados, on_delete: :delete_all),
        null: false

      add :meta_schema_header_detalle_id, references(:meta_schema_header, on_delete: :delete_all),
        null: false

      add :permite_insertar, :boolean, null: false, default: false
      add :permite_actualizar, :boolean, null: false, default: false
      add :permite_borrar, :boolean, null: false, default: false

      add :insert_guid, :string, size: 32, null: false
      add :update_guid, :string, size: 32, null: true
      add :delete_guid, :string, size: 32, null: true
    end

    create unique_index(
             :meta_schema_estado_detalle_permiso,
             [:meta_schema_estado_id, :meta_schema_header_detalle_id],
             name: :meta_estado_detalle_permiso_unico_index
           )

    # Backfill: para cada estado real de cada maestro, y cada catálogo
    # detalle real de ESE maestro, sembrar "permitido" en los 3 flags — así
    # ningún catálogo maestro-detalle existente pierde funcionalidad con
    # este deploy. De acá en adelante (estado nuevo, detalle nuevo, o
    # cualquier combinación sin fila) el default real es todo denegado.
    execute("""
    INSERT INTO meta_schema_estado_detalle_permiso
      (meta_schema_estado_id, meta_schema_header_detalle_id, permite_insertar, permite_actualizar, permite_borrar, insert_guid)
    SELECT e.id, hd.id, true, true, true, md5(random()::text || clock_timestamp()::text)
    FROM meta_schema_estados e
    JOIN meta_schema_header hd ON hd.schema_encabezado_id = e.meta_schema_header_id
    WHERE e.delete_guid IS NULL AND hd.delete_guid IS NULL
    ON CONFLICT DO NOTHING
    """)
  end

  def down do
    drop table(:meta_schema_estado_detalle_permiso)
  end
end
