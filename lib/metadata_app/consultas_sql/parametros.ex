defmodule MetadataApp.ConsultasSql.Parametros do
  @moduledoc """
  Parámetros de una Consulta SQL de uso "servicio" (SPEC-SYS-2509202601
  §11, diseño §11.2-§11.4): cómo se declaran, qué tipos existen y cómo se
  convierte un valor a su tipo.

  Un parámetro declarado es `%{"nombre", "tipo", "obligatorio", "default"}`.
  El `default` se guarda ya convertido a su forma JSON canónica (ver
  `forma_json/2`), así lo que se publica y lo que se ejecuta es lo mismo.
  """

  # tipo -> tipo de Postgres del argumento de la función (diseño §11.2).
  @tipos %{
    "entero" => "bigint",
    "decimal" => "numeric",
    "texto" => "text",
    "fecha" => "date",
    "booleano" => "boolean",
    "lista_enteros" => "bigint[]"
  }

  @formato_nombre ~r/^[a-z][a-z0-9_]{0,40}$/

  def tipos, do: Map.keys(@tipos)

  @doc "Tipo de Postgres de `tipo` (`\"entero\"` -> `\"bigint\"`)."
  def tipo_pg(tipo), do: Map.fetch!(@tipos, tipo)

  @doc """
  Valida y normaliza la lista de parámetros declarados (R35): nombre con
  `#{inspect(@formato_nombre.source)}`, tipo conocido, sin nombres
  repetidos y un default compatible con su tipo. `{:ok, normalizados}`
  o `{:error, mensaje}` con el primer problema encontrado.
  """
  def validar(parametros) when is_list(parametros) do
    parametros
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {parametro, posicion}, {:ok, acumulados} ->
      case validar_uno(parametro, posicion, acumulados) do
        {:ok, normalizado} -> {:cont, {:ok, [normalizado | acumulados]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, normalizados} -> {:ok, Enum.reverse(normalizados)}
      error -> error
    end
  end

  def validar(_parametros), do: {:error, "Los parámetros tienen que ser una lista."}

  defp validar_uno(parametro, posicion, anteriores) when is_map(parametro) do
    nombre = parametro |> valor("nombre") |> to_string() |> String.trim()
    tipo = parametro |> valor("tipo") |> to_string()

    cond do
      not Regex.match?(@formato_nombre, nombre) ->
        {:error,
         "El parámetro #{posicion} tiene un nombre inválido «#{nombre}»: usa minúsculas, números y guion bajo, empezando con letra (máximo 41 caracteres)."}

      Enum.any?(anteriores, &(&1["nombre"] == nombre)) ->
        {:error, "El parámetro «#{nombre}» está repetido."}

      not Map.has_key?(@tipos, tipo) ->
        {:error,
         "El parámetro «#{nombre}» tiene un tipo inválido «#{tipo}». Tipos válidos: #{Enum.join(tipos(), ", ")}."}

      true ->
        with {:ok, obligatorio} <- a_booleano_estricto(valor(parametro, "obligatorio"), nombre),
             {:ok, default} <- normalizar_default(tipo, valor(parametro, "default"), nombre) do
          {:ok,
           %{
             "nombre" => nombre,
             "tipo" => tipo,
             "obligatorio" => obligatorio,
             "default" => default
           }}
        end
    end
  end

  defp validar_uno(_parametro, posicion, _anteriores),
    do: {:error, "El parámetro #{posicion} no tiene el formato esperado."}

  # Llega con llaves string desde la pantalla o el JSON publicado, y con
  # llaves átomo desde código Elixir.
  @llaves_atomo %{
    "nombre" => :nombre,
    "tipo" => :tipo,
    "obligatorio" => :obligatorio,
    "default" => :default
  }

  defp valor(mapa, llave),
    do: Map.get(mapa, llave, Map.get(mapa, Map.fetch!(@llaves_atomo, llave)))

  defp a_booleano_estricto(valor, _nombre) when valor in [true, "true"], do: {:ok, true}

  defp a_booleano_estricto(valor, _nombre) when valor in [false, "false", nil, ""],
    do: {:ok, false}

  defp a_booleano_estricto(valor, nombre),
    do: {:error, "El parámetro «#{nombre}» tiene «obligatorio» inválido: #{inspect(valor)}."}

  defp normalizar_default(_tipo, valor, _nombre) when valor in [nil, ""], do: {:ok, nil}

  defp normalizar_default(tipo, valor, nombre) do
    case convertir(tipo, valor) do
      {:ok, convertido} ->
        {:ok, forma_json(tipo, convertido)}

      :error ->
        {:error,
         "El default del parámetro «#{nombre}» no es un valor válido de tipo #{tipo}: #{inspect(valor)}."}
    end
  end

  @doc """
  Valores de una llamada, en el orden declarado de `parametros`, listos
  para pasarse como `$1..$n` (R40, diseño §11.4 paso 1). Un valor vacío
  (`nil` o `""`) toma el default; si sigue vacío y el parámetro es
  obligatorio, la llamada se rechaza. Cada valor se convierte a su tipo.
  `valores` puede traer llaves string o átomo; las que no corresponden a
  ningún parámetro se ignoran (por `GET` pueden llegar otras, como
  paginación). `{:ok, [valor]}` o `{:error, mensaje}` que nombra el
  parámetro.
  """
  def preparar(parametros, valores) when is_map(valores) do
    parametros
    |> Enum.reduce_while({:ok, []}, fn parametro, {:ok, acumulados} ->
      case preparar_uno(parametro, valor_recibido(valores, parametro["nombre"])) do
        {:ok, valor} -> {:cont, {:ok, [valor | acumulados]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, preparados} -> {:ok, Enum.reverse(preparados)}
      error -> error
    end
  end

  def preparar(_parametros, _valores),
    do: {:error, "Los parámetros de la llamada tienen que ser un mapa."}

  defp preparar_uno(%{"nombre" => nombre, "tipo" => tipo} = parametro, recibido) do
    crudo = if recibido in [nil, ""], do: parametro["default"], else: recibido

    case convertir(tipo, crudo) do
      {:ok, nil} ->
        if parametro["obligatorio"],
          do: {:error, "Falta el parámetro obligatorio «#{nombre}»."},
          else: {:ok, nil}

      {:ok, valor} ->
        {:ok, valor}

      :error ->
        {:error,
         "El parámetro «#{nombre}» no es un valor válido de tipo #{tipo}: #{inspect(crudo)}."}
    end
  end

  # Sin crear átomos: se compara el nombre contra cada llave como texto.
  # `Enum.find` y no `find_value`: un `false` recibido es un valor, no
  # "no llegó".
  defp valor_recibido(valores, nombre) do
    case Enum.find(valores, fn {llave, _valor} -> to_string(llave) == nombre end) do
      {_llave, valor} -> valor
      nil -> nil
    end
  end

  @doc """
  Convierte `valor` al tipo Elixir de `tipo` (tabla del diseño §11.2).
  Acepta la forma nativa y la forma texto, porque por `GET` todo llega
  como texto. `{:ok, convertido}` o `:error`. `nil` es `{:ok, nil}`: la
  obligatoriedad se revisa aparte.
  """
  def convertir(_tipo, nil), do: {:ok, nil}

  def convertir("entero", valor) when is_integer(valor), do: {:ok, valor}
  def convertir("entero", valor) when is_binary(valor), do: entero_de_texto(valor)

  def convertir("decimal", %Decimal{} = valor), do: {:ok, valor}
  def convertir("decimal", valor) when is_integer(valor), do: {:ok, Decimal.new(valor)}
  # Un número con decimales en un cuerpo JSON llega como float.
  def convertir("decimal", valor) when is_float(valor), do: {:ok, Decimal.from_float(valor)}

  def convertir("decimal", valor) when is_binary(valor) do
    case Decimal.parse(String.trim(valor)) do
      {decimal, ""} -> {:ok, decimal}
      _ -> :error
    end
  end

  def convertir("texto", valor) when is_binary(valor), do: {:ok, valor}

  def convertir("fecha", %Date{} = valor), do: {:ok, valor}

  def convertir("fecha", valor) when is_binary(valor) do
    case Date.from_iso8601(String.trim(valor)) do
      {:ok, fecha} -> {:ok, fecha}
      _ -> :error
    end
  end

  def convertir("booleano", valor) when is_boolean(valor), do: {:ok, valor}
  def convertir("booleano", "true"), do: {:ok, true}
  def convertir("booleano", "false"), do: {:ok, false}

  def convertir("lista_enteros", valor) when is_list(valor), do: lista_de_enteros(valor)

  def convertir("lista_enteros", valor) when is_binary(valor) do
    case String.trim(valor) do
      "" -> {:ok, []}
      texto -> texto |> String.split(",") |> lista_de_enteros()
    end
  end

  def convertir(_tipo, _valor), do: :error

  defp entero_de_texto(texto) do
    case Integer.parse(String.trim(texto)) do
      {entero, ""} -> {:ok, entero}
      _ -> :error
    end
  end

  defp lista_de_enteros(elementos) do
    Enum.reduce_while(elementos, {:ok, []}, fn elemento, {:ok, acumulados} ->
      case convertir("entero", elemento) do
        {:ok, entero} when is_integer(entero) -> {:cont, {:ok, [entero | acumulados]}}
        _ -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, enteros} -> {:ok, Enum.reverse(enteros)}
      :error -> :error
    end
  end

  @doc """
  Traduce las referencias `:nombre` del SQL de un Servicio (diseño §11.3,
  D3) a sus dos versiones:

    * `:validacion` — `:nombre` -> `(NULL::tipo_pg)`, para validar el SQL
      con `CREATE TEMP VIEW` y leer sus columnas sin datos reales.
    * `:funcion` — `:nombre` -> `p_nombre`, el argumento de la función.

  Una referencia solo cuenta fuera de textos `'...'`, identificadores
  `"..."`, textos `$tag$...$tag$`, comentarios `--` y `/* */` (anidables,
  como en Postgres), y nunca como parte de un cast `::tipo`. `parametros`
  ya viene validado por `validar/1`. Rechaza una referencia no declarada
  y un parámetro obligatorio que el SQL no usa (R36).
  """
  def traducir(sql, parametros) when is_binary(sql) do
    declarados = Map.new(parametros, &{&1["nombre"], &1})
    {validacion, funcion, usados} = recorrer(sql, declarados, [], [], [])
    usados = Enum.uniq(usados)

    no_declarados = Enum.reject(usados, &Map.has_key?(declarados, &1))

    sin_usar =
      for %{"nombre" => nombre, "obligatorio" => true} <- parametros,
          nombre not in usados,
          do: nombre

    cond do
      no_declarados != [] ->
        {:error,
         "El SQL usa parámetros que no están declarados: #{lista_nombres(no_declarados)}."}

      sin_usar != [] ->
        {:error, "Hay parámetros obligatorios que el SQL no usa: #{lista_nombres(sin_usar)}."}

      true ->
        {:ok,
         %{
           validacion: IO.iodata_to_binary(validacion),
           funcion: IO.iodata_to_binary(funcion),
           usados: usados
         }}
    end
  end

  defp lista_nombres(nombres), do: Enum.map_join(nombres, ", ", &":#{&1}")

  # Las dos salidas se arman en paralelo como iodata en reversa; `usados`
  # junta los nombres en orden de aparición (también en reversa).
  defp recorrer(<<>>, _declarados, val, fun, usados),
    do: {Enum.reverse(val), Enum.reverse(fun), Enum.reverse(usados)}

  # Cast `::tipo`: se copian los dos puntos y el tipo queda como texto normal.
  defp recorrer(<<"::", resto::binary>>, d, val, fun, usados),
    do: recorrer(resto, d, ["::" | val], ["::" | fun], usados)

  defp recorrer(<<":", c, _::binary>> = sql, d, val, fun, usados) when c in ?a..?z do
    <<":", resto::binary>> = sql
    {nombre, resto} = tomar_identificador(resto, "")

    {val_ref, fun_ref} =
      case Map.fetch(d, nombre) do
        {:ok, %{"tipo" => tipo}} -> {"(NULL::#{tipo_pg(tipo)})", "p_" <> nombre}
        # No declarado: se deja tal cual; traducir/2 lo rechaza después.
        :error -> {":" <> nombre, ":" <> nombre}
      end

    recorrer(resto, d, [val_ref | val], [fun_ref | fun], [nombre | usados])
  end

  defp recorrer(<<"'", resto::binary>>, d, val, fun, usados) do
    {texto, resto} = hasta_cierre(resto, ?', "'")
    recorrer(resto, d, [texto | val], [texto | fun], usados)
  end

  defp recorrer(<<"\"", resto::binary>>, d, val, fun, usados) do
    {texto, resto} = hasta_cierre(resto, ?", "\"")
    recorrer(resto, d, [texto | val], [texto | fun], usados)
  end

  defp recorrer(<<"--", resto::binary>>, d, val, fun, usados) do
    {comentario, resto} = hasta_fin_de_linea(resto, "--")
    recorrer(resto, d, [comentario | val], [comentario | fun], usados)
  end

  defp recorrer(<<"/*", resto::binary>>, d, val, fun, usados) do
    {comentario, resto} = comentario_de_bloque(resto, 1, "/*")
    recorrer(resto, d, [comentario | val], [comentario | fun], usados)
  end

  defp recorrer(<<"$", _::binary>> = sql, d, val, fun, usados) do
    case Regex.run(~r/^\$([A-Za-z_][A-Za-z0-9_]*)?\$/, sql) do
      [etiqueta | _] ->
        {texto, resto} =
          texto_dolar(
            binary_part(sql, byte_size(etiqueta), byte_size(sql) - byte_size(etiqueta)),
            etiqueta
          )

        recorrer(resto, d, [texto | val], [texto | fun], usados)

      nil ->
        <<"$", resto::binary>> = sql
        recorrer(resto, d, ["$" | val], ["$" | fun], usados)
    end
  end

  defp recorrer(<<c::utf8, resto::binary>>, d, val, fun, usados) do
    caracter = <<c::utf8>>
    recorrer(resto, d, [caracter | val], [caracter | fun], usados)
  end

  # Byte que no es UTF-8 válido: se copia tal cual; Postgres lo rechaza al validar.
  defp recorrer(<<c, resto::binary>>, d, val, fun, usados),
    do: recorrer(resto, d, [<<c>> | val], [<<c>> | fun], usados)

  defp tomar_identificador(<<c, resto::binary>>, acc) when c in ?a..?z or c in ?0..?9 or c == ?_,
    do: tomar_identificador(resto, acc <> <<c>>)

  defp tomar_identificador(resto, acc), do: {acc, resto}

  # Copia hasta la comilla de cierre; una comilla doblada (`''` o `""`) es
  # un escape y no cierra. Sin cierre, copia hasta el final: Postgres
  # reporta el error de sintaxis al validar.
  defp hasta_cierre(<<q, q, resto::binary>>, q, acc), do: hasta_cierre(resto, q, acc <> <<q, q>>)
  defp hasta_cierre(<<q, resto::binary>>, q, acc), do: {acc <> <<q>>, resto}
  defp hasta_cierre(<<c, resto::binary>>, q, acc), do: hasta_cierre(resto, q, acc <> <<c>>)
  defp hasta_cierre(<<>>, _q, acc), do: {acc, <<>>}

  defp hasta_fin_de_linea(<<"\n", resto::binary>>, acc), do: {acc <> "\n", resto}
  defp hasta_fin_de_linea(<<c, resto::binary>>, acc), do: hasta_fin_de_linea(resto, acc <> <<c>>)
  defp hasta_fin_de_linea(<<>>, acc), do: {acc, <<>>}

  defp comentario_de_bloque(<<"*/", resto::binary>>, 1, acc), do: {acc <> "*/", resto}

  defp comentario_de_bloque(<<"*/", resto::binary>>, n, acc),
    do: comentario_de_bloque(resto, n - 1, acc <> "*/")

  defp comentario_de_bloque(<<"/*", resto::binary>>, n, acc),
    do: comentario_de_bloque(resto, n + 1, acc <> "/*")

  defp comentario_de_bloque(<<c, resto::binary>>, n, acc),
    do: comentario_de_bloque(resto, n, acc <> <<c>>)

  defp comentario_de_bloque(<<>>, _n, acc), do: {acc, <<>>}

  defp texto_dolar(sql, etiqueta) do
    case :binary.split(sql, etiqueta) do
      [contenido, resto] -> {etiqueta <> contenido <> etiqueta, resto}
      [contenido] -> {etiqueta <> contenido, <<>>}
    end
  end

  @doc """
  Forma en que un valor ya convertido se guarda en JSON (el `default`
  declarado): el decimal como texto para no perder precisión y la fecha
  en ISO 8601. Los demás tipos quedan igual.
  """
  def forma_json("decimal", %Decimal{} = valor), do: Decimal.to_string(valor, :normal)
  def forma_json("fecha", %Date{} = valor), do: Date.to_iso8601(valor)
  def forma_json(_tipo, valor), do: valor
end
