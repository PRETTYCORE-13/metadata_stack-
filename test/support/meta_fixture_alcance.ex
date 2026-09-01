defmodule MetadataApp.MetaFixtureAlcance do
  @moduledoc """
  Catálogo de test dedicado a `aplicar_alcance_de_datos/3` (Fase 4a del
  modelo de Alcance de Datos, 2026-08-11) — schema Ecto simple, a mano
  (NO usa MetaCatalogoGenerico) para tener control total de las columnas
  sin arrastrar validaciones de negocio que no vienen al caso acá.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "meta_fixture_alcance" do
    field :nombre, :string
    field :creado_por_id, :id
    field :branch_id, :id
    field :sales_unit_id, :id
    field :inventory_id, :id
    # CatalogoGenerico.actualizar/4 lee esto incondicionalmente (todo
    # catálogo real lo tiene) -- nil = sin motor de estados adoptado.
    field :estado_id, :id
    # CatalogoGenerico.crear/2 (crear_simple/3 y el camino de Motor de
    # Estados) estampa esto incondicionalmente en todo catálogo, igual
    # que insert_guid -- ver estado_id arriba.
    field :fecha_registro, :utc_datetime

    field :insert_guid, :string
    field :update_guid, :string
    field :delete_guid, :string

    timestamps(type: :utc_datetime)
  end

  def changeset(registro, attrs) do
    registro
    |> cast(attrs, [:nombre, :creado_por_id, :branch_id, :sales_unit_id, :inventory_id])
    |> validate_required([:nombre])
  end
end
