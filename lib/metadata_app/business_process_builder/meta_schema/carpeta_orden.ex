defmodule MetadataApp.BusinessProcessBuilder.MetaSchema.CarpetaOrden do
  @moduledoc """
  Orden manual de una carpeta IMPLÍCITA (sin `meta_schema_header` propio,
  inferida solo de la ruta de lo que tiene adentro — ver
  `MetaSchemaContext.construir_arbol/1`). Una carpeta implícita no tiene
  fila donde guardarle un `orden` como las carpetas reales, así que su
  orden se guarda acá, indexado por la ruta acumulada desde la raíz (ej.
  "tienda/electronica") en vez de por `schema_context_name`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "meta_schema_carpeta_orden" do
    field :ruta, :string
    field :orden, :integer
  end

  def changeset(carpeta_orden, attrs) do
    carpeta_orden
    |> cast(attrs, [:ruta, :orden])
    |> validate_required([:ruta, :orden])
    |> unique_constraint(:ruta)
  end
end
