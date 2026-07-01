defmodule MetadataAppWeb.MarcaJSON do
  alias MetadataApp.Catalogos.Marca

  def index(%{marcas: marcas}) do
    %{
      meta_campos: meta_campos(),
      data: for(m <- marcas, do: data(m))
    }
  end

  def show(%{marca: marca}) do
    %{
      meta_campos: meta_campos(),
      data: data(marca)
    }
  end

  defp data(%Marca{} = m) do
    %{
      id:            m.id,
      marca_descrip: m.marca_descrip
    }
  end

  defp meta_campos do
    [
      %{
        schema:       "marca",
        campo:        "id",
        etiqueta:     "Marca Id",
        tipo:         "integer",
        longitud:     nil,
        orden:        1,
        visible:      true,
        editable:     false,
        solo_lectura: true,
        requerido:    true,
        unico:        true,
        placeholder:  nil,
        mayusculas:   false,
        activo:       nil
      },
      %{
        schema:       "marca",
        campo:        "marca_descrip",
        etiqueta:     "Nombre de Marca",
        tipo:         "string",
        longitud:     25,
        orden:        2,
        visible:      true,
        editable:     true,
        solo_lectura: false,
        requerido:    true,
        unico:        true,
        placeholder:  "Ej. NIKE",
        mayusculas:   true,
        activo:       nil
      }
    ]
  end
end
