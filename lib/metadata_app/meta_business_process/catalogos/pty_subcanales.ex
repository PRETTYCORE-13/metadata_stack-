defmodule MetadataApp.MetaBusinessProcess.Catalogos.PtySubcanales do
  use MetadataApp.BusinessProcessBuilder.MetaCatalogoGenerico, tabla: "pty_subcanales", campos: [{:pty_canal_id, :integer, %{opcional: false, tabla_referenciada: "pty_canales"}}, {:pty_subcanal_nombre, :string, %{opcional: false, longitud: 16, formato: nil}}]
end
