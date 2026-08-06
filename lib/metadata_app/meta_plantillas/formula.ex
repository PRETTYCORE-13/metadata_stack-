defmodule MetadataApp.MetaPlantillas.Formula do
  @moduledoc """
  Evaluador seguro de fórmulas para el nodo "campo_calculado" del
  Constructor — nunca ejecuta código Elixir arbitrario (nada de
  `Code.eval_string/1`, `Code.eval_quoted/1`, etc.): tokeniza y evalúa a
  mano un mini-lenguaje con `+ - * /`, paréntesis, condicionales, y tres
  formas de referencia:

  - `{campo}` — un campo del registro actual.
  - `{catalogo#id.campo}` — un campo de UN registro puntual de otro
    catálogo, fijo por id (ej. una tabla de parámetros/config con un solo
    registro) — sin importar si ese catálogo está relacionado a este.
  - `SUM(catalogo.campo)` / `COUNT(catalogo)` / `AVG(catalogo.campo)` /
    `MIN(catalogo.campo)` / `MAX(catalogo.campo)` — agregado sobre TODOS
    los registros vivos de otro catálogo, tampoco requiere relación.

  `IF <comparación> THEN <valor> ELSE <valor>` — a diferencia de "Mostrar
  solo si" (condición de VISIBILIDAD de un nodo entero, ver
  `FichaLive.condicion_cumplida?/3`), esto es una condición que decide el
  VALOR calculado, ej. `IF {stock_actual} > {stock_minimo} THEN "Disponible" ELSE "Agotado"`.
  Solo al nivel superior de la fórmula (no anidado dentro de una cuenta
  aritmética) — la comparación siempre es entre dos expresiones numéricas
  (`> < >= <= == !=`), cada rama puede ser un texto entre comillas o una
  expresión numérica. Por eso `evaluar/2` puede devolver un string además
  de un número.

  Contexto (`{hoy}`, `{usuario_actual}`, `{empresa_activa}`) no es nada
  especial acá adentro — `FichaLive` los mete como pseudo-campos más
  dentro del mismo mapa `valores` que ya recibe `evaluar/2` (ver
  `contexto_actual/1`), así que se usan con la misma sintaxis `{campo}`
  de siempre. `{hoy}` es una fecha real (no un string), así que
  `{fecha_vencimiento} - {hoy}` da directamente la diferencia en días.
  Una fórmula que es UN SOLO campo (ej. `{usuario_actual}` a secas)
  devuelve ese valor tal cual sea texto, fecha o número, sin forzarlo a
  número como sí hace cualquier fórmula con operadores.

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
  alias MetadataApp.MetaPlantillas.FormulaCache

  @funciones_agregado ~w(SUM COUNT AVG MIN MAX)

  @doc """
  Evalúa `formula` contra `valores` (mapa `%{"campo" => valor_crudo}` del
  registro actual — valor_crudo puede ser string, Decimal, integer o
  float, se castea solo).
  """
  @spec evaluar(String.t(), map()) :: {:ok, float() | String.t()} | {:error, term()}
  def evaluar(formula, valores) when is_binary(formula) and is_map(valores) do
    with {:ok, tokens} <- tokenizar(formula) do
      evaluar_tokens(tokens, valores)
    end
  end

  def evaluar(_formula, _valores), do: {:error, :formula_invalida}

  defp evaluar_tokens([{:kw, :if} | resto], valores), do: evaluar_condicion(resto, valores)

  # Fórmula que es UN SOLO campo (ej. "{usuario_actual}" o "{hoy}", los
  # pseudo-campos de Contexto) devuelve el valor tal cual, sea texto,
  # fecha o número — no lo fuerza por a_numero/1 como hace la rama
  # aritmética de abajo. Así "un campo calculado que solo muestra un dato"
  # (de contexto o de un campo real) no exige que ese dato sea numérico.
  defp evaluar_tokens([{:campo, nombre}], valores), do: resolver_campo_crudo(nombre, valores)

  defp evaluar_tokens(tokens, valores) do
    with {:ok, {valor, resto}} <- expr(tokens, valores) do
      case resto do
        [] -> {:ok, valor}
        _ -> {:error, :tokens_sobrantes}
      end
    end
  end

  # IF <expr> <cmp> <expr> THEN <rama> ELSE <rama> — solo al nivel superior
  # de la fórmula, ver moduledoc. Cualquier pieza faltante o fuera de orden
  # (THEN sin ELSE, comparador ausente, tokens de más al final) cae en el
  # `else` de abajo — fail-open, no hay forma de que esto crashee la ficha.
  defp evaluar_condicion(tokens, valores) do
    with {:ok, {izq, [{:cmp, op} | resto2]}} <- expr(tokens, valores),
         {:ok, {der, resto3}} <- expr(resto2, valores),
         [{:kw, :then} | resto4] <- resto3,
         {:ok, {rama_then, [{:kw, :else} | resto5]}} <- rama_condicion(resto4, valores),
         {:ok, {rama_else, []}} <- rama_condicion(resto5, valores) do
      {:ok, if(comparar(op, izq, der), do: rama_then, else: rama_else)}
    else
      _ -> {:error, :condicion_mal_formada}
    end
  end

  defp rama_condicion([{:str, s} | resto], _valores), do: {:ok, {s, resto}}
  defp rama_condicion(tokens, valores), do: expr(tokens, valores)

  defp comparar(:gt, a, b), do: a > b
  defp comparar(:lt, a, b), do: a < b
  defp comparar(:gte, a, b), do: a >= b
  defp comparar(:lte, a, b), do: a <= b
  defp comparar(:eq, a, b), do: a == b
  defp comparar(:neq, a, b), do: a != b

  @doc """
  Tokeniza `formula` para el Constructor de chips — literalmente el mismo
  tokenizer que usa `evaluar/2`, expuesto de solo lectura para que la
  representación visual (cada chip) nunca se pueda desincronizar de lo que
  realmente se va a evaluar. Fail-open: una fórmula a medio armar o
  inválida no rompe la pantalla, devuelve `[]` en vez de levantar.
  """
  @spec tokens_para_mostrar(String.t()) :: list()
  def tokens_para_mostrar(formula) when is_binary(formula) do
    case tokenizar(formula) do
      {:ok, tokens} -> tokens
      {:error, _motivo} -> []
    end
  end

  def tokens_para_mostrar(_formula), do: []

  @doc """
  Mezcla en `base` (mapa con los valores YA resueltos: campos reales del
  registro + pseudo-campos de Contexto) el resultado de evaluar TODOS los
  nodos "campo_calculado" de `definicion` (bajo su propia etiqueta),
  resolviendo dependencias entre ellos (uno puede referenciar a otro con
  `{OtroCampo}`, misma sintaxis que un campo real) con guarda anti-ciclos:
  un campo que depende de sí mismo, directa o indirectamente, se corta sin
  recursión infinita y queda sin resolver (fail-open, mismo criterio que
  el resto de este módulo — la fórmula que dependía de eso da error de
  campo no numérico, no rompe nada).

  Reusado tanto por la Ficha 360° (`FichaLive`, contra los valores reales
  del registro) como por el Constructor (vista previa de una fórmula
  ANTES de publicarla, contra un registro de muestra) — un solo lugar de
  verdad para esta resolución, así nunca se desincronizan entre sí.
  """
  @spec resolver_calculados(map() | nil, map()) :: map()
  def resolver_calculados(definicion, base) do
    nodos = MetadataApp.MetaPlantillas.nodos_de_tipo(definicion, "campo_calculado")

    Enum.reduce(nodos, base, fn nodo, valores ->
      nombre = nodo["propiedades"]["etiqueta"]

      if nombre in [nil, ""] or Map.has_key?(valores, nombre) do
        valores
      else
        {_valor, valores2} = resolver_uno(nombre, nodos, valores, MapSet.new())
        valores2
      end
    end)
  end

  defp resolver_uno(nombre, _nodos, valores, _en_progreso) when is_map_key(valores, nombre) do
    {Map.get(valores, nombre), valores}
  end

  defp resolver_uno(nombre, nodos, valores, en_progreso) do
    if MapSet.member?(en_progreso, nombre) do
      {nil, valores}
    else
      case Enum.find(nodos, &(&1["propiedades"]["etiqueta"] == nombre)) do
        nil ->
          {nil, valores}

        nodo ->
          formula = nodo["propiedades"]["formula"] || ""
          dependencias = formula |> tokens_para_mostrar() |> Enum.flat_map(&campo_referenciado/1)
          en_progreso2 = MapSet.put(en_progreso, nombre)

          valores_con_deps =
            Enum.reduce(dependencias, valores, fn dep, acc ->
              {_valor, acc2} = resolver_uno(dep, nodos, acc, en_progreso2)
              acc2
            end)

          resultado =
            case evaluar(formula, valores_con_deps) do
              {:ok, v} -> v
              {:error, _motivo} -> nil
            end

          {resultado, Map.put(valores_con_deps, nombre, resultado)}
      end
    end
  end

  defp campo_referenciado({:campo, nombre}), do: [nombre]
  defp campo_referenciado(_token), do: []

  @doc """
  Formatea el resultado de `evaluar/2` para mostrarlo — mismo criterio
  para la Ficha 360° y para la vista previa del Constructor (un solo
  lugar de verdad, así el Constructor nunca muestra algo distinto de lo
  que después va a aparecer publicado). `propiedades` es
  `nodo["propiedades"]` de un "campo_calculado" (`"formato"`:
  `"numero"`|`"moneda"`|`"porcentaje"`, `"decimales"`: entero 0-10).
  """
  @spec formatear({:ok, float() | String.t()} | {:error, term()}, map()) :: String.t()
  def formatear({:ok, texto}, _propiedades) when is_binary(texto), do: texto

  def formatear({:ok, numero}, propiedades) when is_number(numero) do
    decimales =
      case Integer.parse(to_string(propiedades["decimales"] || "2")) do
        {n, _} when n in 0..10 -> n
        _ -> 2
      end

    texto = :erlang.float_to_binary(numero * 1.0, decimals: decimales)

    case propiedades["formato"] do
      "moneda" -> "$" <> con_separador_miles(texto)
      "porcentaje" -> texto <> "%"
      _ -> texto
    end
  end

  def formatear({:error, _motivo}, _propiedades), do: "—"

  # "12345.67" -> "12,345.67" (y "-12345.67" -> "-12,345.67") — sin
  # dependencia nueva, solo para "moneda". Nunca se usa antes de pasar por
  # float_to_binary/2 arriba, así que siempre llega con "." como separador
  # decimal (nunca ninguno si decimales: 0).
  defp con_separador_miles(numero_texto) do
    case String.split(numero_texto, ".", parts: 2) do
      [entero, decimales] -> separar_miles(entero) <> "." <> decimales
      [entero] -> separar_miles(entero)
    end
  end

  defp separar_miles(entero) do
    {signo, digitos} =
      if String.starts_with?(entero, "-") do
        {"-", String.trim_leading(entero, "-")}
      else
        {"", entero}
      end

    agrupado =
      digitos
      |> String.reverse()
      |> String.graphemes()
      |> Enum.chunk_every(3)
      |> Enum.map_join(",", &Enum.join/1)
      |> String.reverse()

    signo <> agrupado
  end

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

  # Comparadores de 2 caracteres ANTES que los de 1 — si no, ">=" se
  # partiría en ">" seguido de un "=" suelto que el catch-all final
  # rechaza como carácter inválido.
  defp tokenizar_lista([?>, ?= | resto], acc), do: tokenizar_lista(resto, [{:cmp, :gte} | acc])
  defp tokenizar_lista([?<, ?= | resto], acc), do: tokenizar_lista(resto, [{:cmp, :lte} | acc])
  defp tokenizar_lista([?=, ?= | resto], acc), do: tokenizar_lista(resto, [{:cmp, :eq} | acc])
  defp tokenizar_lista([?!, ?= | resto], acc), do: tokenizar_lista(resto, [{:cmp, :neq} | acc])
  defp tokenizar_lista([?> | resto], acc), do: tokenizar_lista(resto, [{:cmp, :gt} | acc])
  defp tokenizar_lista([?< | resto], acc), do: tokenizar_lista(resto, [{:cmp, :lt} | acc])

  # Literal de texto entre comillas — solo lo usan las ramas THEN/ELSE de
  # un condicional (ver rama_condicion/2), ej. IF ... THEN "Disponible" ELSE "Agotado".
  defp tokenizar_lista([?" | resto], acc) do
    case Enum.split_while(resto, &(&1 != ?")) do
      {_texto, []} -> {:error, :comilla_sin_cerrar}
      {texto, [?" | resto2]} -> tokenizar_lista(resto2, [{:str, List.to_string(texto)} | acc])
    end
  end

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

    case nombre do
      "IF" -> tokenizar_lista(resto, [{:kw, :if} | acc])
      "THEN" -> tokenizar_lista(resto, [{:kw, :then} | acc])
      "ELSE" -> tokenizar_lista(resto, [{:kw, :else} | acc])
      _ -> tokenizar_agregado(nombre, resto, acc)
    end
  end

  defp tokenizar_lista([c | _], _acc), do: {:error, {:caracter_invalido, <<c::utf8>>}}

  defp tokenizar_agregado(nombre, [?( | resto], acc) do
    case Enum.split_while(resto, &(&1 != ?))) do
      {_arg, []} -> {:error, :parentesis_sin_cerrar}
      {arg, [?) | resto2]} -> tokenizar_lista(resto2, [{:agregado, nombre, arg |> List.to_string() |> String.trim()} | acc])
    end
  end

  defp tokenizar_agregado(nombre, _resto, _acc), do: {:error, {:funcion_sin_parentesis, nombre}}

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
      [_, catalogo, id_texto, campo] -> resolver_fijo(catalogo, String.to_integer(id_texto), campo, &a_numero/1)
      nil -> a_numero(Map.get(valores, nombre))
    end
  end

  # Mismo camino que resolver_campo/2 pero sin forzar numérico — usado por
  # "una fórmula de un solo campo" (ver evaluar_tokens/2), donde el valor
  # se muestra tal cual sea texto, fecha o número.
  defp resolver_campo_crudo(nombre, valores) do
    case Regex.run(@regex_fijo, nombre) do
      [_, catalogo, id_texto, campo] -> resolver_fijo(catalogo, String.to_integer(id_texto), campo, &{:ok, a_valor_mostrable(&1)})
      nil -> {:ok, a_valor_mostrable(Map.get(valores, nombre))}
    end
  end

  defp resolver_fijo(catalogo, id, campo, caster) do
    with {:ok, modulo} <- resolver_modulo(catalogo) do
      try do
        registro = CatalogoGenerico.obtener!(modulo, id)

        case Map.fetch(registro, String.to_existing_atom(campo)) do
          {:ok, valor} -> caster.(valor)
          :error -> {:error, {:campo_inexistente, catalogo, campo}}
        end
      rescue
        Ecto.NoResultsError -> {:error, {:registro_no_encontrado, catalogo, id}}
        ArgumentError -> {:error, {:campo_inexistente, catalogo, campo}}
      end
    end
  end

  # --- SUM/COUNT/AVG/MIN/MAX(catalogo[.campo]) — agregado, otro catálogo -
  #
  # Cacheado con TTL corto (FormulaCache, `@ttl_agregado_ms`): sin esto,
  # un "campo_calculado" con un agregado recorre el catálogo referenciado
  # ENTERO en memoria (vía CatalogoGenerico.listar/1 o contar/1) en CADA
  # evaluación — y en la Ficha 360°, `evaluar/2` se llama en cada render,
  # que a su vez dispara con CADA tecla tipeada en CUALQUIER campo del
  # formulario (phx-change="validar"), tenga o no que ver con la fórmula.
  # Unos pocos segundos de vida alcanzan para absorber una ráfaga de
  # teclas sin sentir el catálogo entero recorriéndose de nuevo en cada
  # una — esto no es un dato que tenga que ser exacto al segundo, es un
  # cálculo en pantalla. Los errores NUNCA se cachean (son baratos: fallan
  # antes de llegar a listar/contar nada, ver resolver_modulo/2 y
  # a_atomo_existente/2 más abajo).

  @ttl_agregado_ms :timer.seconds(5)

  defp evaluar_agregado("COUNT", arg) do
    with {:ok, catalogo} <- parse_solo_catalogo(arg) do
      con_cache({"COUNT", catalogo}, fn ->
        with {:ok, modulo} <- resolver_modulo(catalogo) do
          {:ok, CatalogoGenerico.contar(modulo) * 1.0}
        end
      end)
    end
  end

  defp evaluar_agregado(nombre, arg) when nombre in @funciones_agregado do
    with {:ok, {catalogo, campo}} <- parse_catalogo_campo(arg) do
      con_cache({nombre, catalogo, campo}, fn ->
        with {:ok, modulo} <- resolver_modulo(catalogo),
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
      end)
    end
  end

  defp evaluar_agregado(nombre, _arg), do: {:error, {:funcion_desconocida, nombre}}

  defp con_cache(clave, calculo) do
    tabla = FormulaCache.tabla()
    agora = System.monotonic_time(:millisecond)

    case :ets.lookup(tabla, clave) do
      [{^clave, valor, expira_en}] when expira_en > agora ->
        {:ok, valor}

      _ ->
        case calculo.() do
          {:ok, valor} = ok ->
            :ets.insert(tabla, {clave, valor, agora + @ttl_agregado_ms})
            ok

          error ->
            error
        end
    end
  end

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

  # Para poder restar fechas dentro de una fórmula (ej. "{hoy} - {fecha_vencimiento}"
  # → días de diferencia) — Date.to_gregorian_days/1 da un entero que crece
  # 1 por día, así la resta entre dos fechas da directamente "cuántos días".
  defp a_numero(%Date{} = d), do: {:ok, Date.to_gregorian_days(d) * 1.0}

  defp a_numero(_), do: :error

  # A diferencia de a_numero/1 (que SIEMPRE fuerza un número o falla), esto
  # nunca falla — usado solo para "fórmula de un solo campo" (ver
  # evaluar_tokens/2), donde lo que sea que valga el campo se muestra tal
  # cual, sin exigir que sea numérico.
  defp a_valor_mostrable(nil), do: ""
  defp a_valor_mostrable(%Decimal{} = d), do: Decimal.to_float(d)
  defp a_valor_mostrable(%Date{} = d), do: Calendar.strftime(d, "%d/%m/%Y")
  defp a_valor_mostrable(n) when is_number(n), do: n * 1.0
  defp a_valor_mostrable(s) when is_binary(s), do: s
  defp a_valor_mostrable(otro), do: to_string(otro)
end
