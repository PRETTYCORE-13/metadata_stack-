defmodule MetadataApp.Autenticacion.Permiso do
  @moduledoc """
  `accion` NO está limitado a un vocabulario fijo (`leer`/`crear`/`editar`/
  `eliminar` son solo la convención para el CRUD genérico de `/api/:tabla`
  y el "leer" que poda el menú) — también puede ser el `accion` literal de
  una transición del motor de estados de ese catálogo (ej. `"aprobar"`,
  `"reactivar"`), que es un vocabulario abierto por catálogo. Ver
  `MetadataApp.MetaStateEngine` (chequeo automático por transición).
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "meta_schema_permiso" do
    field :recurso, :string
    field :accion, :string
    field :descripcion, :string

    field :insert_guid, :string
    field :update_guid, :string
    field :delete_guid, :string
  end

  def changeset(permiso, attrs) do
    permiso
    |> cast(attrs, [:recurso, :accion, :descripcion])
    |> validate_required([:recurso, :accion])
    |> validate_length(:accion, max: 50)
    |> unique_constraint([:recurso, :accion])
  end
end
