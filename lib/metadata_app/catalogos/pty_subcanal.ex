defmodule MetadataApp.Catalogos.PtySubcanal do
  use MetadataApp.MetaCatalogoGenerico, tabla: "pty_subcanal", campos: [{:subcanal_nombre, :string, %{longitud: 150, formato: nil}}, {:id_canal, :integer, %{tabla_referenciada: "pty_canal"}}]
end
