defmodule MetadataAppWeb.BodyReaderLoteEndpoints do
  @moduledoc """
  SPEC-SYS-1009202602 (R81, design.md §17) -- el `Plug.Parsers` del
  `Endpoint` no trae `length:` explícito (default de la librería,
  8.000.000 bytes) porque ese límite aplica a CUALQUIER POST de la
  plataforma. Un lote de alta (§17) de decenas de miles de registros
  puede superarlo con facilidad -- este `body_reader` sube el límite
  ÚNICAMENTE para `/api/consultas` (la ruta comodín de Endpoints, ver
  router.ex), sin tocar el default del resto de la app.
  """

  @limite_lote 200_000_000

  def read_body(conn, opts) do
    if String.starts_with?(conn.request_path, "/api/consultas") do
      Plug.Conn.read_body(conn, Keyword.put(opts, :length, @limite_lote))
    else
      Plug.Conn.read_body(conn, opts)
    end
  end
end
