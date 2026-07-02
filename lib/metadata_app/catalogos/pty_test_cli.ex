defmodule MetadataApp.Catalogos.PtyTestCli do
  use MetadataApp.MetaCatalogoGenerico, tabla: "pty_test_clis", campos: [{:pty_test_cli_nombre, :string, 15}]
end
