defmodule MetadataApp.Repo.Migrations.AgregarOrdenColumnasTablaAMetaSchemaHeader do
  use Ecto.Migration

  # Get View unificado (Campos de Control + Campos de negocio en una sola
  # grilla arrastrable, a pedido explícito -- antes los de control eran 7
  # botones de mostrar/ocultar sin ningún orden, siempre en una secuencia
  # fija en CatalogoLive). orden_columnas_tabla mezcla nombres de campo real
  # (schema_context_field) y claves fijas de control ("id", "estado", "trn",
  # "empresa", "branch", "inventory_location", "sales_unit", "creado_por")
  # -- lista vacía = catálogo nunca configurado esto, CatalogoLive cae al
  # orden de siempre (compatibilidad con todo lo ya publicado).
  #
  # mostrar_creado_por_en_tabla sigue el mismo patrón que
  # mostrar_id_en_tabla/mostrar_estado_en_tabla — un campo de control más.
  # "Creado por" no es una columna física nueva: se resuelve contra
  # meta_schema_auditoria (bc + entidad_id, operacion 'alta'), tomando el
  # maestro cuando el catálogo es detalle -- ver CatalogoLive.
  def change do
    alter table(:meta_schema_header) do
      add :orden_columnas_tabla, {:array, :string}, null: false, default: []
      add :mostrar_creado_por_en_tabla, :boolean, null: false, default: false
    end
  end
end
