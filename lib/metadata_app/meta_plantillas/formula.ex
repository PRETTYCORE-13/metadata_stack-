defmodule MetadataApp.MetaPlantillas.Formula do
  @moduledoc """
  Evaluador seguro de fórmulas para el nodo "campo_calculado" del
  Constructor — nunca ejecuta código Elixir arbitrario (nada de
  `Code.eval_string/1`, `Code.eval_quoted/1`, etc.): tokeniza y evalúa a
  mano un mini-lenguaje aritmético con `+ - * /`, paréntesis, y tres formas
  de referencia:

  - `{campo}` — un campo del registro actual.
  - `{catalogo#id.campo}` — un campo de UN registro puntual de otro
    catálogo, fijo por id (ej. una tabla de parámetros/config con un solo
    registro) — sin importar si ese catálogo está relacionado a este.
  - `SUM(catalogo.campo)` / `COUNT(catalogo)` / `AVG(catalogo.campo)` /
    `MIN(catalogo.campo)` / `MAX(catalogo.campo)` — agregado sobre TODOS
    los registros vivos de otro catálogo, tampoco requiere relación.

  Fail-open a propósito, mismo criterio que `FichaLive.condicion_cumplida?/3`:
  una fórmula mal escrita, un catálogo/campo que no existe, un registro que
  no aparece, o un campo sin valor numérico, no rompe la Ficha 360° —
  `evaluar/2` devuelve `{:error, motivo}` y quien llama decide qué mostrar
  (típicamente "—").

  Los agregados recorren el catálogo entero en memoria (vía
  `CatalogoGenerico.listar/2`, ya usado en toda la app) — bien para los
  volúmenes de un catálogo maestro (decenas/cientos de filas), no pensado
  para tablas de millones de registros.
  """

  alias MetadataApp.BusinessProcessBuilder.{MetaSchemaContext, CatalogoGenerico}

  @funciones_agregado ~w(SUM COUNT AVG MIN MAX)

  @doc """
  Evalúa `formula` contra `valores` (mapa `%{"campo" => valor_crudo}` del
  registro actual — valor_crudo puede ser string, Decimal, integer o
  float, se castea solo).
  """
  @spec evaluar(String.t(), map()) :: {:ok, float()} | {:error, term()}
  def evaluar(formula, valores) when is_binary(formula) and is_map(valores) do
    with {:ok, tokens} <- tokenizar(formula),
         {:ok, {valor, resto}} <- expr(tokens, valores) do
      case resto do
        [] -> {:ok, valor}
        _ -> {:error, :tokens_sobrantes}
      end
    end
  end

  def evaluar(_formula, _valores), do: {:error, :formula_invalida}

  # --- Tokenizer -----------------------------------------------------

  defp tokenizar(formula), do: formula |> String.to_charlist() |> tokenizar_lista([])

  defp tokenizar_lista([], acc), do: {:ok, Enum.reverse(acc)}
  defp tokenizar_lista([c | resto], acc) when c in [?\s, ?\t, ?\n, ?\r], do: tokenizar_lista(resto, acc)
  defp tokenizar_lista([?( | resto], acc), do: tokenizar_lista(resto, [{:lparen} | acc])
  defp tokenizar_lista([?) | resto], acc), do: tokenizar_lista(resto, [{:rparen} | acc])
  defp tokenizar_lista([?+ | resto], acc), do: tokenizar_lista(resto, [{:op, :+} | acc])
  defp tokenizar_lista([?- | resto], acc), do: tokenizar_lista(resto, [{:op, :-} | acc])
  defp tokenizar_lista([?* | resto], acc), do: tokenizar_lista(resto, [{:op, :*} | acc])
  defp tokenizar_lista([?/ | resto], acc), do: tokenizar_lista(resto, [{:op, :/} | acc])

  defp tokenizar_lista([?{ | resto], acc) do
    case Enum.split_while(resto, &(&1 != ?})) do
      {_campo, []} -> {:error, :llave_sin_cerrar}
      {campo, [?} | resto2]} -> tokenizar_lista(resto2, [{:campo, campo |> List.to_string() |> String.trim()} | acc])
    end
  end

  defp tokenizar_lista([c | _] = lista, acc) when c in ?0..?9 do
    {digitos, resto} = Enum.split_while(lista, &(&1 in ?0..?9 or &1 == ?.))
    texto = List.to_string(digitos)
    texto_normalizado = if String.contains?(texto, "."), do: texto, else: texto <> ".0"

    case Float.parse(texto_normalizado) do
      {n, _} -> tokenizar_lista(resto, [{:num, n} | acc])
      :error -> {:error, {:numero_invalido, texto}}
    end
  end

  # SUM(...) / COUNT(...) / AVG(...) / MIN(...) / MAX(...) — mayúsculas a
  # propósito, así no se confunde con un nombre de catálogo (siempre
  # minúscula, mismo criterio que schema_context_name en todo el proyecto).
  # El argumento se captura crudo (como el contenido de "{...}") y se
  # parsea aparte en evaluar_agregado/2 — no es una expresión aritmética,
  # es "catalogo" o "catalogo.campo".
  defp tokenizar_lista([c | _] = lista, acc) when c in ?A..?Z do
    {letras, resto} = Enum.split_while(lista, &(&1 in ?A..?Z))
    nombre = List.to_string(letras)

    case resto do
      [?( | resto2] ->
        case Enum.split_while(resto2, &(&1 != ?))) do
          {_arg, []} -> {:error, :parentesis_sin_cerrar}
          {arg, [?) | resto3]} -> tokenizar_lista(resto3, [{:agregado, nombre, arg |> List.to_string() |> String.trim()} | acc])
        end

      _ ->
        {:error, {:funcion_sin_parentesis, nombre}}
    end
  end

  defp tokenizar_lista([c | _], _acc), do: {:error, {:caracter_invalido, <<c::utf8>>}}

  # --- Parser + evaluador recursivo, en el mismo paso ------------------
  # Precedencia estándar: expr (+ -) por encima de term (* /) por encima
  # de factor (número | campo | agregado | -factor | "(" expr ")").

  defp expr(tokens, valores) do
    with {:ok, {izq, resto}} <- term(tokens, valores) do
      expr_resto(izq, resto, valores)
    end
  end

  defp expr_resto(acc, [{:op, op} | resto], valores) when op in [:+, :-] do
    with {:ok, {der, resto2}} <- term(resto, valores) do
      nuevo = if op == :+, do: acc + der, else: acc - der
      expr_resto(nuevo, resto2, valores)
    end
  end

  defp expr_resto(acc, resto, _valores), do: {:ok, {acc, resto}}

  defp term(tokens, valores) do
    with {:ok, {izq, resto}} <- factor(tokens, valores) do
      term_resto(izq, resto, valores)
    end
  end

  defp term_resto(acc, [{:op, :*} | resto], valores) do
    with {:ok, {der, resto2}} <- factor(resto, valores) do
      term_resto(acc * der, resto2, valores)
    end
  end

  defp term_resto(acc, [{:op, :/} | resto], valores) do
    with {:ok, {der, resto2}} <- factor(resto, valores) do
      if der == 0 do
        {:error, :division_por_cero}
      else
        term_resto(acc / der, resto2, valores)
      end
    end
  end

  defp term_resto(acc, resto, _valores), do: {:ok, {acc, resto}}

  defp factor([{:num, n} | resto], _valores), do: {:ok, {n, resto}}

  defp factor([{:campo, nombre} | resto], valores) do
    case resolver_campo(nombre, valores) do
      {:ok, n} -> {:ok, {n, resto}}
      :error -> {:error, {:campo_no_numerico, nombre}}
      {:error, _} = erro -> erro
    end
  end

  defp factor([{:agregado, nombre, arg} | resto], _valores) do
    case evaluar_agregado(nombre, arg) do
      {:ok, n} -> {:ok, {n, resto}}
      {:error, _} = erro -> erro
    end
  end

  defp factor([{:op, :-} | resto], valores) do
    with {:ok, {n, resto2}} <- factor(resto, valores), do: {:ok, {-n, resto2}}
  end

  defp factor([{:lparen} | resto], valores) do
    with {:ok, {n, resto2}} <- expr(resto, valores) do
      case resto2 do
        [{:rparen} | resto3] -> {:ok, {n, resto3}}
        _ -> {:error, :parentesis_sin_cerrar}
      end
    end
  end

  defp factor([], _valores), do: {:error, :expresion_incompleta}
  defp factor(_tokens, _valores), do: {:error, :token_inesperado}

  # --- "{campo}" — local, o "{catalogo#id.campo}" — fijo, otro catálogo --

  @regex_fijo ~r/^([a-z][a-z0-9_]*)#(\d+)\.([a-z_][a-z0-9_]*)$/

  defp resolver_campo(nombre, valores) do
    case Regex.run(@regex_fijo, nombre) do
      [_, catalogo, id_texto, campo] -> resolver_fijo(catalogo, String.to_integer(id_texto), campo)
      nil -> a_numero(Map.get(valores, nombre))
    end
  end

  defp resolver_fijo(catalogo, id, campo) do
    with {:ok, modulo} <- resolver_modulo(catalogo) do
      try do
        registro = CatalogoGenerico.obtener!(modulo, id)

        case Map.fetch(registro, String.to_existing_atom(campo)) do
          {:ok, valor} -> a_numero(valor)
          :error -> {:error, {:campo_inexistente, catalogo, campo}}
        end
      rescue
        Ecto.NoResultsError -> {:error, {:registro_no_encontrado, catalogo, id}}
        ArgumentError -> {:error, {:campo_inexistente, catalogo, campo}}
      end
    end
  end

  # --- SUM/COUNT/AVG/MIN/MAX(catalogo[.campo]) — agregado, otro catálogo -

  defp evaluar_agregado("COUNT", arg) do
    with {:ok, catalogo} <- parse_solo_catalogo(arg),
         {:ok, modulo} <- resolver_modulo(catalogo) do
      {:ok, CatalogoGenerico.contar(modulo) * 1.0}
    end
  end

  defp evaluar_agregado(nombre, arg) when nombre in @funciones_agregado do
    with {:ok, {catalogo, campo}} <- parse_catalogo_campo(arg),
         {:ok, modulo} <- resolver_modulo(catalogo),
         {:ok, campo_atom} <- a_atomo_existente(campo, catalogo) do
      numeros =
        modulo
        |> CatalogoGenerico.listar()
        |> Enum.map(&Map.get(&1, campo_atom))
        |> Enum.map(&a_numero/1)
        |> Enum.filter(&match?({:ok, _}, &1))
        |> Enum.map(fn {:ok, n} -> n end)

      agregar(nombre, numeros)
    end
  end

  defp evaluar_agregado(nombre, _arg), do: {:error, {:funcion_desconocida, nombre}}

  defp agregar(_nombre, []), do: {:ok, 0.0}
  defp agregar("SUM", numeros), do: {:ok, Enum.sum(numeros)}
  defp agregar("AVG", numeros), do: {:ok, Enum.sum(numeros) / length(numeros)}
  defp agregar("MIN", numeros), do: {:ok, Enum.min(numeros)}
  defp agregar("MAX", numeros), do: {:ok, Enum.max(numeros)}

  defp parse_solo_catalogo(arg) do
    case Regex.run(~r/^([a-z][a-z0-9_]*)$/, String.trim(arg)) do
      [_, catalogo] -> {:ok, catalogo}
      nil -> {:error, {:argumento_invalido, arg}}
    end
  end

  defp parse_catalogo_campo(arg) do
    case Regex.run(~r/^([a-z][a-z0-9_]*)\.([a-z_][a-z0-9_]*)$/, String.trim(arg)) do
      [_, catalogo, campo] -> {:ok, {catalogo, campo}}
      nil -> {:error, {:argumento_invalido, arg}}
    end
  end

  defp resolver_modulo(catalogo) do
    case MetaSchemaContext.modulo_por_nombre(catalogo) do
      nil -> {:error, {:catalogo_desconocido, catalogo}}
      modulo -> {:ok, modulo}
    end
  end

  defp a_atomo_existente(campo, catalogo) do
    {:ok, String.to_existing_atom(campo)}
  rescue
    ArgumentError -> {:error, {:campo_inexistente, catalogo, campo}}
  end

  defp a_numero(n) when is_number(n), do: {:ok, n * 1.0}

  # Los campos "decimal" del motor (ej. precio_lista) llegan como Decimal,
  # no como float/integer nativo — sin este clause, cualquier campo_calculado
  # que referencie uno de esos campos fallaba siempre con :campo_no_numerico.
  defp a_numero(%Decimal{} = d), do: {:ok, Decimal.to_float(d)}

  defp a_numero(s) when is_binary(s) do
    case Float.parse(String.trim(s)) do
      {n, _resto} -> {:ok, n}
      :error -> :error
    end
  end

  defp a_numero(_), do: :error
end
