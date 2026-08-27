defmodule MetadataApp.PanelControl do
  @moduledoc """
  Contexto de "Panel Control" (Sysadmin, 2026-08-26) -- levantar una app
  nueva (dominio + deploy) sobre el cluster k3s ya migrado (ver
  MetadataApp.Ssh, MetadataApp.PanelControl.{Hostinger,Desplegador}), para
  cualquier imagen Docker, no solo metadata_stack. Mismo criterio de
  modelo propio y chico que MetadataApp.Ambientes/Integraciones -- nada
  cifrado acá (las credenciales SSH/DNS viven en Ambiente/Credencial, ya
  resueltos), solo el registro de qué se pidió desplegar y en qué quedó.
  """

  import Ecto.Query
  alias MetadataApp.Repo
  alias MetadataApp.PanelControl.App

  @doc "Todas las apps vivas, orden alfabético por nombre."
  def listar_apps do
    from(a in App, where: is_nil(a.delete_guid), order_by: a.nombre, preload: [:ambiente])
    |> Repo.all()
  end

  def obtener_app!(id) do
    from(a in App, where: a.id == ^id and is_nil(a.delete_guid), preload: [:ambiente])
    |> Repo.one!()
  end

  def crear_app(attrs) do
    %App{}
    |> App.changeset_creacion(attrs)
    |> Ecto.Changeset.change(%{insert_guid: generar_guid()})
    |> Repo.insert()
  end

  @doc "Usado por Desplegador mientras avanza -- nunca desde un formulario de usuario."
  def actualizar_estado(%App{} = app, attrs) do
    app
    |> App.changeset_estado(attrs)
    |> Ecto.Changeset.change(%{update_guid: generar_guid()})
    |> Repo.update()
  end

  @doc "Soft-delete, mismo criterio que el resto del sistema."
  def eliminar_app(%App{} = app) do
    app
    |> Ecto.Changeset.change(%{delete_guid: generar_guid()})
    |> Repo.update()
  end

  defp generar_guid, do: Ecto.UUID.generate() |> String.replace("-", "")
end
