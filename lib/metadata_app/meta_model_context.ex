defmodule MetadataApp.MetaModelContext do
  alias MetadataApp.Repo
  alias MetadataApp.MetaModelContext.MetaModelSchema
  import Ecto.Query

  # Listar todos los campos de un schema
  def listar_campos(schema_nombre) do
    from(c in MetaModelSchema,
      where: c.schema_nombre == ^schema_nombre,
      where: is_nil(c.delete_guid),
      order_by: [asc: fragment("(propiedades->>'orden')::integer")]
    )
    |> Repo.all()
  end

  # Obtener un campo específico
  def obtener_campo!(id), do: Repo.get!(MetaModelSchema, id)

  # Crear — solo el sistema lo usa al inicializar schemas
  def crear_campo(attrs) do
    %MetaModelSchema{}
    |> MetaModelSchema.changeset(attrs)
    |> Ecto.Changeset.change(%{insert_guid: generar_guid()})
    |> Repo.insert()
  end

  # Crear varios campos de un mismo schema en una sola transacción.
  # Si alguno falla, se revierten todos (todo o nada).
  def crear_campos(schema_nombre, campos) when is_list(campos) do
    Repo.transaction(fn ->
      Enum.map(campos, fn campo_attrs ->
        attrs = Map.put(campo_attrs, "schema_nombre", schema_nombre)

        case crear_campo(attrs) do
          {:ok, campo} -> campo
          {:error, changeset} -> Repo.rollback(changeset)
        end
      end)
    end)
  end

  # Actualizar propiedades — lo usa el administrador
  # Cambio inmediato: se sobreescribe el registro
  def actualizar_campo(%MetaModelSchema{} = config, attrs) do
    config
    |> MetaModelSchema.changeset(attrs)
    |> Ecto.Changeset.change(%{update_guid: generar_guid()})
    |> Repo.update()
  end

  # Baja lógica del campo
  def eliminar_campo(%MetaModelSchema{} = config) do
    config
    |> Ecto.Changeset.change(%{delete_guid: generar_guid()})
    |> Repo.update()
  end

  # Serializa un campo para exponerlo como meta_campos (ej. embebido en las
  # respuestas de los catálogos). Sin id ni guids — son detalle interno de
  # meta_schema, no del catálogo que describen.
  def serializar_campo(%MetaModelSchema{} = campo) do
    %{schema_nombre: campo.schema_nombre, campo: campo.campo, propiedades: campo.propiedades}
  end

  defp generar_guid do
    Ecto.UUID.generate() |> String.replace("-", "")
  end
end
