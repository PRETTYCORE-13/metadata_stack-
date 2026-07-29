defmodule MetadataApp.Repo.Migrations.CorregirIndiceUnicoDetalleConEncabezado do
  use Ecto.Migration
  import Ecto.Query

  # Bug real (R3, Catálogo Maestro-Detalle): el índice único de negocio de
  # un catálogo detalle (`<tabla>_unico_index`) nunca incluía
  # `encabezado_id` — la misma combinación de valores de negocio quedaba
  # prohibida para SIEMPRE en TODA la tabla, aunque fuera de dos maestros
  # (encabezados) distintos, que es el caso normal (ej. dos empleados no
  # podían tener el mismo rol+fecha, dos comandos no podían repetir
  # contacto/teléfono/email/owner). Ver
  # `CatalogoGenerador.crear_migracion/3`, ya corregido para catálogos
  # nuevos — esta migración recompone el índice de cada catálogo detalle
  # YA EXISTENTE para que quede scoped por `encabezado_id`, sin cambiar el
  # nombre del índice (el `unique_constraint/3` del changeset generado
  # solo matchea por nombre, no por columnas, así que sigue funcionando
  # sin tocar ese lado).
  def up do
    detalles_por_header()
    |> Enum.each(fn {tabla, campos} ->
      if tabla_existe?(tabla) and campos != [] do
        columnas = Enum.join(["encabezado_id" | campos], ", ")
        execute("DROP INDEX IF EXISTS #{tabla}_unico_index")
        execute("CREATE UNIQUE INDEX #{tabla}_unico_index ON #{tabla} (#{columnas})")
      end
    end)
  end

  def down do
    :ok
  end

  defp detalles_por_header do
    headers =
      from(h in "meta_schema_header",
        where: not is_nil(h.schema_encabezado_id) and is_nil(h.delete_guid),
        select: %{id: h.id, nombre: h.schema_context_name}
      )
      |> repo().all()

    Enum.map(headers, fn h ->
      campos =
        from(d in "meta_schema_detail",
          where: d.meta_schema_header_id == ^h.id and is_nil(d.delete_guid) and d.schema_context_field != "id",
          select: d.schema_context_field
        )
        |> repo().all()

      {h.nombre, campos}
    end)
  end

  defp tabla_existe?(tabla) do
    %{rows: [[existe]]} = repo().query!("SELECT to_regclass($1) IS NOT NULL AS existe", [tabla])
    existe
  end
end
