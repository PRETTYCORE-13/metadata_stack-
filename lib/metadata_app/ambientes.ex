defmodule MetadataApp.Ambientes do
  @moduledoc """
  Contexto de "Ambientes de Deploy" (UI/ambientes-deploy, 2026-08-16) --
  servidores donde `mix motor.desplegar` puede desplegar la imagen ya
  construida, con sus credenciales SSH cifradas (mismo criterio que
  MetadataApp.Integraciones.Credencial: modelo propio y chico, no parte
  del sistema genérico de catálogos, para que ningún camino genérico
  tenga que saber nunca mostrar/filtrar un campo cifrado).
  """

  import Ecto.Query
  alias MetadataApp.Repo
  alias MetadataApp.Ambientes.Ambiente

  @doc "Todos los ambientes vivos, orden alfabético por nombre."
  def listar_ambientes do
    from(a in Ambiente, where: is_nil(a.delete_guid), order_by: a.nombre)
    |> Repo.all()
  end

  def obtener_ambiente!(id) do
    from(a in Ambiente, where: a.id == ^id and is_nil(a.delete_guid))
    |> Repo.one!()
  end

  @doc "Usado por mix motor.desplegar -- resuelve por nombre, no por id (más cómodo desde la línea de comandos)."
  def obtener_ambiente_por_nombre(nombre) do
    from(a in Ambiente, where: a.nombre == ^nombre and is_nil(a.delete_guid))
    |> Repo.one()
  end

  def crear_ambiente(attrs) do
    %Ambiente{}
    |> Ambiente.changeset_creacion(attrs)
    |> Ecto.Changeset.change(%{insert_guid: generar_guid()})
    |> Repo.insert()
  end

  def actualizar_ambiente(%Ambiente{} = ambiente, attrs) do
    ambiente
    |> Ambiente.changeset_edicion(attrs)
    |> Ecto.Changeset.change(%{update_guid: generar_guid()})
    |> Repo.update()
  end

  @doc "Soft-delete, mismo criterio que el resto del sistema."
  def eliminar_ambiente(%Ambiente{} = ambiente) do
    ambiente
    |> Ecto.Changeset.change(%{delete_guid: generar_guid()})
    |> Repo.update()
  end

  defp generar_guid, do: Ecto.UUID.generate() |> String.replace("-", "")
end
