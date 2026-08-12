defmodule MetadataApp.Autenticacion.RolAlcance do
  @moduledoc """
  Alcance de datos de un rol en UN catálogo puntual (Fase 3 del modelo de
  Alcance de Datos, 2026-08-11) — mismo patrón que RolPermiso, pero en vez
  de {rol, permiso} es {rol, catálogo, tipo}. Deny-by-default: sin fila acá
  para (rol, catálogo), ese rol no tiene alcance ampliado en ese catálogo
  (ver Permissions.alcance_tipo_efectivo/2 para la resolución completa,
  incluida la unión entre roles y el bypass de "administrador").
  """
  use Ecto.Schema
  import Ecto.Changeset

  @tipos ~w(propio branch sales_unit inventory_location empresa global)

  schema "meta_schema_rol_alcance" do
    belongs_to :rol, MetadataApp.Autenticacion.Rol
    belongs_to :header, MetadataApp.BusinessProcessBuilder.MetaSchema.Header, foreign_key: :meta_schema_header_id

    field :alcance_tipo, :string

    field :insert_guid, :string
    field :update_guid, :string
    field :delete_guid, :string
  end

  def tipos, do: @tipos

  def changeset(rol_alcance, attrs) do
    rol_alcance
    |> cast(attrs, [:rol_id, :meta_schema_header_id, :alcance_tipo])
    |> validate_required([:rol_id, :meta_schema_header_id, :alcance_tipo])
    |> validate_inclusion(:alcance_tipo, @tipos)
    |> unique_constraint([:rol_id, :meta_schema_header_id])
  end
end
