defmodule MetadataApp.Catalogos.PtyMarca do
  use MetadataApp.MetaCatalogoGenerico,
    tabla: "pty_marcas",
    campos: [
      {:pty_marca_nombre, :string, %{longitud: 15}},
      {:pty_marca_orden, :integer, %{}}
    ]
end
