defmodule MetadataApp.CatalogoRegistry do
  alias MetadataApp.Repo
  alias MetadataApp.CatalogoRegistry.Catalogo
  import Ecto.Query

  # Registra un catálogo nuevo en el índice tabla -> módulo de schema.
  # Idempotente: si la tabla ya está registrada, no hace nada.
  def registrar(tabla, schema_nombre, modulo) do
    case obtener_por_tabla(tabla) do
      nil ->
        %Catalogo{}
        |> Ecto.Changeset.change(%{
          tabla: tabla,
          schema_nombre: schema_nombre,
          modulo: modulo,
          insert_guid: generar_guid()
        })
        |> Repo.insert()

      catalogo ->
        {:ok, catalogo}
    end
  end

  def obtener_por_tabla(tabla) do
    Repo.one(
      from c in Catalogo, where: c.tabla == ^tabla and is_nil(c.delete_guid)
    )
  end

  def obtener_por_schema_nombre(schema_nombre) do
    Repo.one(
      from c in Catalogo, where: c.schema_nombre == ^schema_nombre and is_nil(c.delete_guid)
    )
  end

  # Borrado total del catálogo (no soft-delete): a diferencia de las filas de
  # negocio, borrar un catálogo es una operación administrativa irreversible,
  # no algo que deba quedar recuperable vía delete_guid.
  def eliminar(tabla) do
    from(c in Catalogo, where: c.tabla == ^tabla)
    |> Repo.delete_all()

    :ok
  end

  # Resuelve el módulo de schema Ecto (ej. MetadataApp.Catalogos.PtyMoto) a
  # partir del nombre de tabla en la URL. nil si no existe o no compiló.
  def modulo_por_tabla(tabla) do
    with %Catalogo{modulo: modulo} <- obtener_por_tabla(tabla),
         modulo_completo <- Module.concat(MetadataApp.Catalogos, modulo),
         true <- Code.ensure_loaded?(modulo_completo) do
      modulo_completo
    else
      _ -> nil
    end
  end

  defp generar_guid do
    Ecto.UUID.generate() |> String.replace("-", "")
  end
end
