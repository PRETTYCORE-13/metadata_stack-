defmodule MetadataApp.MetaBusinessProcess.Catalogos.PtySubcanal do
  use MetadataApp.BusinessProcessBuilder.MetaCatalogoGenerico, tabla: "pty_subcanal", campos: [{:subcanal_nombre, :string, %{opcional: false, longitud: 150, formato: nil}}, {:id_canal, :integer, %{opcional: false, tabla_referenciada: "pty_canal"}}]
end
