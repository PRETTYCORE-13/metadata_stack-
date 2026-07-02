defmodule MetadataApp.Catalogos.PtyMotos do
  use MetadataApp.MetaCatalogoGenerico,
    tabla: "pty_motos",
    campos: [
      {:pty_moto_nombre, :string, %{longitud: 30}},
      {:pty_moto_tipo, :string, %{longitud: 15}},
      {:pty_moto_licencia, :string, %{longitud: 10}}
    ]
end
