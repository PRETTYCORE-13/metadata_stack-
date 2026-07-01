defmodule MetadataApp.Catalogos do
  import Ecto.Query
  alias MetadataApp.Repo
  alias MetadataApp.Catalogos.Marca


  @doc """
  Filtra por una cadena utulizando un between
  1.-Valida que la cadena no sea nula
  2.- hace un like por la cadena que recibe
  3.- Crea función listar_marcas para ser llamada por su controller
      Lanza consulta ECTO ->filtrar_por_nombre
  """

  def listar_marcas(filtros \\ %{}) do
    Marca
    |> filtrar_por_nombre(filtros["marca_descrip"])
    |> Repo.all()
  end

  defp filtrar_por_nombre(query, nil), do: query
  defp filtrar_por_nombre(query, ""), do: query

  defp filtrar_por_nombre(query, nombre) do
    where(query, [m], ilike(m.marca_descrip, ^"%#{nombre}%"))
  end

  def obtener_marca!(id) do
    Repo.get!(Marca, id)
  end

  def crear_marca(attrs) do
    %Marca{}
    |> Marca.changeset(attrs)
    |> Ecto.Changeset.change(%{insert_guid: generar_guid()})
    |> Repo.insert()
  end

  def actualizar_marca(%Marca{} = marca, attrs) do
    marca
    |> Marca.changeset(attrs)
    |> Ecto.Changeset.change(%{update_guid: generar_guid()})
    |> Repo.update()
  end

  def eliminar_marca(%Marca{} = marca) do
    marca
    |> Ecto.Changeset.change(%{delete_guid: generar_guid()})
    |> Repo.update()
  end

  defp generar_guid do
    Ecto.UUID.generate() |> String.replace("-", "")
  end
end
