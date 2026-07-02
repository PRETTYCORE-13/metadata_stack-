defmodule MetadataApp.CatalogoGenerico do
  alias MetadataApp.Repo

  def listar(schema_mod) do
    Repo.all(schema_mod)
  end

  def obtener!(schema_mod, id) do
    Repo.get!(schema_mod, id)
  end

  def crear(schema_mod, attrs) do
    schema_mod
    |> struct()
    |> schema_mod.changeset(attrs)
    |> Ecto.Changeset.change(%{insert_guid: generar_guid()})
    |> Repo.insert()
  end

  def actualizar(registro, attrs) do
    schema_mod = registro.__struct__

    registro
    |> schema_mod.changeset(attrs)
    |> Ecto.Changeset.change(%{update_guid: generar_guid()})
    |> Repo.update()
  end

  def eliminar(registro) do
    registro
    |> Ecto.Changeset.change(%{delete_guid: generar_guid()})
    |> Repo.update()
  end

  def serializar(registro) do
    registro
    |> Map.from_struct()
    |> Map.drop([:__meta__, :insert_guid, :update_guid, :delete_guid])
  end

  defp generar_guid do
    Ecto.UUID.generate() |> String.replace("-", "")
  end
end
