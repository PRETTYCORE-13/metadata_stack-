defmodule MetadataAppWeb.BusinessProcessBuilder.ConsultaSqlController do
  # GET /api/<sql view> -- lectura de una SQL View (schema_context_type: 4,
  # SPEC-SYS-2509202601 R21). Se llama desde CatalogoController.index/2,
  # mismo path "/api/:tabla" y misma seguridad de API que un catálogo o una
  # Consulta Ecto. Sin filtros (el SQL es fijo) y sin show/create/update/
  # delete: una SQL View nunca transacciona.
  use MetadataAppWeb, :controller

  alias MetadataApp.ConsultasSql

  @por_pagina_default 25
  @por_pagina_maximo 100

  def index(conn, %{"tabla" => nombre} = params) do
    pagina = params |> Map.get("pagina") |> entero(1) |> max(1)
    por_pagina = params |> Map.get("por_pagina") |> entero(@por_pagina_default) |> max(1) |> min(@por_pagina_maximo)

    case ConsultasSql.filas(nombre, conn.assigns[:current_scope], pagina, por_pagina) do
      {:ok, resultado} ->
        json(
          conn,
          Jason.OrderedObject.new(
            meta_campos: Enum.map(resultado.columnas, &%{clave: &1["nombre"], tipo: &1["tipo"]}),
            data: resultado.filas,
            paginacion: %{
              pagina: resultado.pagina,
              por_pagina: resultado.por_pagina,
              total_filas: resultado.total,
              total_paginas: max(div(resultado.total + por_pagina - 1, por_pagina), 1)
            }
          )
        )

      {:error, motivo} ->
        conn
        |> put_status(:service_unavailable)
        |> json(%{error: ConsultasSql.mensaje_ejecucion(motivo)})
    end
  end

  defp entero(nil, default), do: default

  defp entero(valor, default) do
    case Integer.parse(to_string(valor)) do
      {n, _} -> n
      :error -> default
    end
  end
end
