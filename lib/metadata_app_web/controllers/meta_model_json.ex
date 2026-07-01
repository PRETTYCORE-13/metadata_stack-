defmodule MetadataAppWeb.MetaModelJSON do
  alias MetadataApp.MetaModelContext.MetaModelSchema

  def index(%{campos: campos}) do
    %{data: for(c <- campos, do: data(c))}
  end

  def show(%{campo: campo}) do
    %{data: data(campo)}
  end

  defp data(%MetaModelSchema{} = c) do
    %{
      id:            c.id,
      schema_nombre: c.schema_nombre,
      campo:         c.campo,
      propiedades:   c.propiedades
    }
  end
end
