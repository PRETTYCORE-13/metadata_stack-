defmodule MetadataApp.BorradoresMotor do
  @moduledoc """
  CRUD de borradores del wizard "Nuevo catálogo" (`meta_schema_temp`).

  Guarda el JSON completo de lo que el usuario armó en memoria en
  `BcNuevoCompletoLive` (Contexto+Campos+Estados+Transiciones+Reglas) para
  poder retomarlo después — no toca `meta_schema_header` ni genera ninguna
  tabla física; eso solo pasa cuando el borrador se "gradúa" con
  `MetaEstadosAdmin.crear_proceso_completo/1`.
  """

  import Ecto.Query
  alias MetadataApp.Repo
  alias MetadataApp.MetaSchema.Temp

  def listar_borradores do
    from(t in Temp, where: is_nil(t.delete_guid), order_by: [desc: t.updated_at])
    |> Repo.all()
  end

  def obtener_borrador(id) do
    from(t in Temp, where: t.id == ^id and is_nil(t.delete_guid))
    |> Repo.one()
  end

  def crear_borrador(nombre, contenido_json) do
    %Temp{}
    |> Temp.changeset(%{nombre: nombre, contenido_json: contenido_json})
    |> Ecto.Changeset.change(%{insert_guid: generar_guid()})
    |> Repo.insert()
  end

  def actualizar_borrador(%Temp{} = temp, nombre, contenido_json) do
    temp
    |> Temp.changeset(%{nombre: nombre, contenido_json: contenido_json})
    |> Ecto.Changeset.change(%{update_guid: generar_guid()})
    |> Repo.update()
  end

  def eliminar_borrador(%Temp{} = temp) do
    temp
    |> Ecto.Changeset.change(%{delete_guid: generar_guid()})
    |> Repo.update()
  end

  def eliminar_borrador(id) when is_integer(id) or is_binary(id) do
    case obtener_borrador(id) do
      nil -> {:error, :no_encontrado}
      temp -> eliminar_borrador(temp)
    end
  end

  defp generar_guid do
    Ecto.UUID.generate() |> String.replace("-", "")
  end
end
