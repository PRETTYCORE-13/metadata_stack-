defmodule MetadataApp.MetaBusinessProcess.Catalogos.PtyEquiposNfl do
  use MetadataApp.BusinessProcessBuilder.MetaCatalogoGenerico, tabla: "pty_equipos_nfl", campos: [{:pty_equipos_nfl_nombre_equipo, :string, %{opcional: false, longitud: 60, formato: nil}}]
end
