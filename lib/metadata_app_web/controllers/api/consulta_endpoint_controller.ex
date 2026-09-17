defmodule MetadataAppWeb.Api.ConsultaEndpointController do
  @moduledoc """
  Ejecuta un endpoint API publicado a partir de una Consulta
  (SPEC-SYS-1009202602). Única acción `:invocar` -- de SOLO LECTURA por
  construcción (R12): es la única función ruteada sobre
  "/api/consultas/*ruta" (ver router.ex), nunca se declara ningún verbo
  de escritura sobre esta ruta.

  Corre en el pipeline `:api_consulta_endpoint` (solo `accepts`, SIN
  sesión/cookie de admin) -- la única identidad posible acá es una
  credencial del endpoint (R19.1, agregado 2026-09-11 -- un endpoint
  puede tener VARIAS, cada una con su propio subconjunto de campos
  permitidos), nunca un Usuario logueado.
  """
  use MetadataAppWeb, :controller

  require Logger

  alias MetadataApp.ConsultaEndpoints
  alias MetadataApp.MetaConsultas
  alias MetadataApp.MetaSchema.ConsultaEndpointLog
  alias MetadataApp.Repo
  alias MetadataAppWeb.AuditoriaContexto

  @por_pagina_default 50
  @por_pagina_maximo 200
  @timeout_ms 10_000

  # R35-R38 (agregado 2026-09-11) -- tope recomendado de 5.000 por
  # lote en modo cursor, independiente del de pagina/por_pagina.
  @limite_cursor_default 5_000
  @limite_cursor_maximo 5_000

  def invocar(conn, %{"ruta" => segmentos} = params) do
    inicio = System.monotonic_time(:millisecond)
    metodo = conn.method |> to_string() |> String.downcase()
    ruta = Enum.join(segmentos, "/")

    case ConsultaEndpoints.obtener_publicado(metodo, ruta) do
      nil -> responder_sin_endpoint(conn, :not_found, "Endpoint no encontrado")
      endpoint -> autenticar_y_ejecutar(conn, endpoint, metodo, params, inicio)
    end
  end

  defp autenticar_y_ejecutar(conn, endpoint, metodo, params, inicio) do
    case api_key_presentada(conn) do
      :error ->
        responder(conn, :unauthorized, %{"error" => "Falta Authorization: Bearer <api_key>"}, endpoint, nil, inicio)

      {:ok, key} ->
        case ConsultaEndpoints.resolver_credencial(endpoint.id, key) do
          nil ->
            responder(conn, :unauthorized, %{"error" => "API key inválida"}, endpoint, nil, inicio)

          credencial ->
            ejecutar(conn, endpoint, credencial, metodo, params, inicio)
        end
    end
  end

  # R20 -- exclusivamente `Authorization: Bearer <key>`, nunca query
  # string ni body (esos ni se miran acá para la key).
  defp api_key_presentada(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> key] when key != "" -> {:ok, key}
      _ -> :error
    end
  end

  defp ejecutar(conn, endpoint, credencial, metodo, params, inicio) do
    valores_externos = Map.drop(params, ["ruta"])

    if endpoint.metodo == "post" and endpoint.permite_alta do
      ejecutar_alta(conn, endpoint, credencial, valores_externos, inicio)
    else
      ejecutar_consulta(conn, endpoint, credencial, metodo, valores_externos, inicio)
    end
  end

  # R54-R58 -- un endpoint POST con `permite_alta` inserta un registro
  # en vez de ejecutar la Consulta; el body NUNCA se interpreta como
  # filtros acá (son dos modos mutuamente excluyentes por endpoint,
  # decisión explícita -- no se mezclan alta y query en la misma
  # llamada).
  defp ejecutar_alta(conn, endpoint, credencial, valores_externos, inicio) do
    case ConsultaEndpoints.crear_registro(endpoint, endpoint.consulta, valores_externos) do
      {:ok, registro} ->
        responder(conn, :created, %{"data" => %{"id" => registro.id}}, endpoint, credencial, inicio, 1)

      {:error, reason} ->
        mensaje = mensaje_error_alta(reason)
        responder(conn, :unprocessable_entity, %{"error" => mensaje}, endpoint, credencial, inicio, 0)
    end
  end

  # R65 -- el body no coincidió con NINGÚN campo habilitado (Content-Type
  # incorrecto, nombres de campo viejos/mal escritos, etc.) -- lista los
  # campos que SÍ acepta para que el caller pueda comparar de una.
  defp mensaje_error_alta({:body_sin_coincidencias, campos_alta}) do
    "El body no coincide con ningún campo habilitado para este endpoint -- revisá que el header " <>
      "\"Content-Type: application/json\" esté presente y que los nombres de campo sean exactamente: " <>
      Enum.join(campos_alta, ", ")
  end

  defp mensaje_error_alta(%Ecto.Changeset{} = changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc -> String.replace(acc, "%{#{key}}", to_string(value)) end)
    end)
    |> Enum.flat_map(fn {campo, mensajes} -> Enum.map(mensajes, &"#{campo}: #{&1}") end)
    |> Enum.join("; ")
  end

  defp mensaje_error_alta({:referencia_no_encontrada, campo, valor}),
    do: "El campo \"#{campo}\" -- no se encontró ningún registro con esa descripción (\"#{valor}\")"

  defp mensaje_error_alta({:referencia_ambigua, campo, valor}),
    do: "El campo \"#{campo}\" -- hay más de un registro con la misma descripción (\"#{valor}\"), no se puede identificar cuál usar"

  defp mensaje_error_alta({:sin_campo_descripcion, campo, _valor}),
    do: "El campo \"#{campo}\" no tiene un campo de descripción configurado para identificarlo"

  defp mensaje_error_alta(reason), do: inspect(reason)

  defp ejecutar_consulta(conn, endpoint, credencial, metodo, valores_externos, inicio) do
    case ConsultaEndpoints.construir_overrides(endpoint.consulta, endpoint, valores_externos) do
      {:error, {:parametros_faltantes, claves}} ->
        mensaje = "Faltan parámetros obligatorios: #{Enum.join(claves, ", ")}"
        responder(conn, :bad_request, %{"error" => mensaje}, endpoint, credencial, inicio)

      {:ok, overrides} ->
        # R37 -- la PRESENCIA del parámetro "cursor" elige el modo,
        # nunca reemplaza el camino de pagina/por_pagina (decisión
        # explícita: "no modifiques lo que ya existe").
        if Map.has_key?(valores_externos, "cursor") do
          ejecutar_con_cursor(conn, endpoint, credencial, overrides, valores_externos, inicio)
        else
          ejecutar_paginado(conn, endpoint, credencial, metodo, overrides, valores_externos, inicio)
        end
    end
  end

  # R35-R38 -- keyset sobre el id del catálogo base, nunca cuenta el
  # total (Repo.aggregate sobre millones de filas sería el mismo
  # problema que este modo busca evitar). `tiene_mas` es una
  # aproximación barata: si el lote vino exactamente lleno, puede haber
  # más -- el próximo pedido, si no hay nada, se autocorrige solo
  # (data: [], tiene_mas: false).
  defp ejecutar_con_cursor(conn, endpoint, credencial, overrides, valores_externos, inicio) do
    case decodificar_cursor(Map.get(valores_externos, "cursor")) do
      :error ->
        responder(conn, :bad_request, %{"error" => "Cursor inválido"}, endpoint, credencial, inicio)

      {:ok, cursor_id} ->
        limite = valores_externos |> Map.get("limite") |> parse_entero(@limite_cursor_default) |> clamp(1, @limite_cursor_maximo)

        resultado =
          MetaConsultas.ejecutar(
            endpoint.consulta,
            {:empresa_fija, endpoint.empresa_id},
            %{},
            [despues_de_id: cursor_id, limit: limite, timeout: @timeout_ms],
            nil,
            overrides
          )

        filas = Enum.map(resultado.filas, &Map.take(serializar_mapa(&1), credencial.campos_permitidos))
        tiene_mas = length(resultado.filas) == limite
        cursor_siguiente = if tiene_mas, do: resultado.filas |> List.last() |> Map.fetch!(:id) |> codificar_cursor()

        body = %{"data" => filas, "meta" => %{"cursor_siguiente" => cursor_siguiente, "tiene_mas" => tiene_mas}}
        responder(conn, :ok, body, endpoint, credencial, inicio, length(resultado.filas))
    end
  rescue
    error in [DBConnection.ConnectionError] ->
      Logger.warning("Endpoint #{endpoint.id} excedió el tiempo de ejecución (cursor): #{inspect(error)}")
      responder(conn, :gateway_timeout, %{"error" => "Tiempo de ejecución excedido"}, endpoint, credencial, inicio)
  end

  defp decodificar_cursor(valor) when valor in [nil, ""], do: {:ok, nil}

  defp decodificar_cursor(texto) do
    with {:ok, decodificado} <- Base.url_decode64(texto, padding: false),
         {id, ""} <- Integer.parse(decodificado) do
      {:ok, id}
    else
      _ -> :error
    end
  end

  defp codificar_cursor(id), do: id |> Integer.to_string() |> Base.url_encode64(padding: false)

  defp ejecutar_paginado(conn, endpoint, credencial, _metodo, overrides, valores_externos, inicio) do
    {pagina, por_pagina} = resolver_paginacion(valores_externos)
    offset = (pagina - 1) * por_pagina

    resultado =
      MetaConsultas.ejecutar(
        endpoint.consulta,
        {:empresa_fija, endpoint.empresa_id},
        %{},
        [limit: por_pagina, offset: offset, timeout: @timeout_ms],
        nil,
        overrides
      )

    # R43-R44 -- cada fila se recorta a los campos permitidos de ESTA
    # credencial, nunca configurable por quien llama (ningún ?fields=...
    # se lee acá ni en ningún otro lado de este controller).
    filas = Enum.map(resultado.filas, &Map.take(serializar_mapa(&1), credencial.campos_permitidos))

    body = %{
      "data" => filas,
      "meta" => %{
        "pagina" => pagina,
        "por_pagina" => por_pagina,
        "total" => resultado.total_filas,
        "total_paginas" => total_paginas(resultado.total_filas, por_pagina)
      }
    }

    responder(conn, :ok, body, endpoint, credencial, inicio, length(resultado.filas))
  rescue
    error in [DBConnection.ConnectionError] ->
      Logger.warning("Endpoint #{endpoint.id} excedió el tiempo de ejecución: #{inspect(error)}")
      responder(conn, :gateway_timeout, %{"error" => "Tiempo de ejecución excedido"}, endpoint, credencial, inicio)
  end

  defp serializar_mapa(mapa), do: Map.new(mapa, fn {clave, valor} -> {to_string(clave), valor} end)

  defp resolver_paginacion(valores) do
    pagina = valores |> Map.get("pagina") |> parse_entero(1) |> max(1)
    por_pagina = valores |> Map.get("por_pagina") |> parse_entero(@por_pagina_default) |> clamp(1, @por_pagina_maximo)
    {pagina, por_pagina}
  end

  defp parse_entero(nil, default), do: default
  defp parse_entero(valor, _default) when is_integer(valor), do: valor

  defp parse_entero(valor, default) do
    case Integer.parse(to_string(valor)) do
      {n, _resto} -> n
      :error -> default
    end
  end

  defp clamp(n, minimo, maximo), do: n |> max(minimo) |> min(maximo)

  defp total_paginas(0, _por_pagina), do: 1
  defp total_paginas(total_filas, por_pagina), do: ceil(total_filas / por_pagina)

  # Sin endpoint resuelto todavía (404) -- no hay de qué empresa auditar,
  # se omite la fila de auditoría (nada que auditar todavía).
  defp responder_sin_endpoint(conn, status, mensaje) do
    conn |> put_status(status) |> json(%{"error" => mensaje})
  end

  defp responder(conn, status, body, endpoint, credencial, inicio, cantidad_registros \\ nil) do
    duracion_ms = System.monotonic_time(:millisecond) - inicio
    registrar_auditoria(endpoint, credencial, conn, status, duracion_ms, cantidad_registros)
    conn |> put_status(status) |> json(body)
  end

  # R33/R34 -- NUNCA una columna con la key ni con los valores de los
  # parámetros de la llamada; `credencial_id` (2026-09-11) es solo un
  # número interno, nil si la llamada nunca llegó a resolver una. Un
  # fallo acá no debe tumbar la respuesta ya armada para el consumidor
  # externo.
  defp registrar_auditoria(endpoint, credencial, conn, status, duracion_ms, cantidad_registros) do
    %ConsultaEndpointLog{}
    |> ConsultaEndpointLog.changeset(%{
      meta_schema_consulta_endpoint_id: endpoint.id,
      meta_schema_consulta_endpoint_credencial_id: credencial && credencial.id,
      fecha_hora: DateTime.utc_now(),
      empresa_id: endpoint.empresa_id,
      ip: AuditoriaContexto.desde_conn(conn).ip,
      metodo: endpoint.metodo,
      resultado_http: Plug.Conn.Status.code(status),
      duracion_ms: duracion_ms,
      cantidad_registros: cantidad_registros
    })
    |> Repo.insert()
  rescue
    error -> Logger.error("No se pudo auditar invocación del endpoint #{endpoint.id}: #{inspect(error)}")
  end
end
