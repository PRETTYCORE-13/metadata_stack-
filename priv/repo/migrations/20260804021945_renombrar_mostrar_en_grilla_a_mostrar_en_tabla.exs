defmodule MetadataApp.Repo.Migrations.RenombrarMostrarEnGrillaAMostrarEnTabla do
  use Ecto.Migration

  # "grilla" es término rioplatense (Argentina/Uruguay) que no se entiende
  # en México, donde corre este sistema — se renombra acá la property JSON
  # guardada en schema_context_properties de meta_schema_detail, en línea
  # con el código (ver MetaSchemaContext.mostrar_en_tabla?/1 y el checkbox
  # "En tabla" de BcMotorLive → Campos), para que el nombre interno y lo
  # que ve el usuario digan lo mismo.
  def up do
    execute """
    UPDATE meta_schema_detail
    SET schema_context_properties = (schema_context_properties - 'mostrar_en_grilla')
      || jsonb_build_object('mostrar_en_tabla', schema_context_properties -> 'mostrar_en_grilla')
    WHERE schema_context_properties ? 'mostrar_en_grilla'
    """
  end

  def down do
    execute """
    UPDATE meta_schema_detail
    SET schema_context_properties = (schema_context_properties - 'mostrar_en_tabla')
      || jsonb_build_object('mostrar_en_grilla', schema_context_properties -> 'mostrar_en_tabla')
    WHERE schema_context_properties ? 'mostrar_en_tabla'
    """
  end
end
