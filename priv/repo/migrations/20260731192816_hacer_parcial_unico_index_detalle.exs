defmodule MetadataApp.Repo.Migrations.HacerParcialUnicoIndexDetalle do
  use Ecto.Migration

  # meta_schema_detail_unico_index no excluía filas borradas lógicamente
  # (eliminar_detalle/1 es soft-delete, solo pone delete_guid). Efecto real:
  # borrar un campo del Builder y volver a agregar uno con el MISMO nombre
  # chocaba contra la fila vieja (ya borrada) y tiraba "ya existe un campo
  # con este nombre" aunque el campo activo ya no exista — reproducido con
  # pty_gasto_diario (agregar "valor", borrarlo, agregar "concepto",
  # volver a agregar "valor" -> error). Partial index, mismo criterio que
  # ya usa el resto del código para soft-delete (is_nil(delete_guid) en
  # cualquier query de listado).
  def up do
    drop unique_index(:meta_schema_detail, [:meta_schema_header_id, :schema_context_field],
           name: :meta_schema_detail_unico_index
         )

    create unique_index(:meta_schema_detail, [:meta_schema_header_id, :schema_context_field],
             name: :meta_schema_detail_unico_index,
             where: "delete_guid IS NULL"
           )
  end

  def down do
    drop unique_index(:meta_schema_detail, [:meta_schema_header_id, :schema_context_field],
           name: :meta_schema_detail_unico_index
         )

    create unique_index(:meta_schema_detail, [:meta_schema_header_id, :schema_context_field],
             name: :meta_schema_detail_unico_index
           )
  end
end
