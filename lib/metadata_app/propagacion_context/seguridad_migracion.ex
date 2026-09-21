defmodule MetadataApp.PropagacionContext.SeguridadMigracion do
  @moduledoc """
  Detector de seguridad de migraciones (SPEC-SYS-1809202603 R10a) --
  decide si el `down` de Ecto de una migración puede correr AUTOMÁTICO
  contra un destino real, o si necesita confirmación manual.

  **Hallazgo que fija el diseño**: la enorme mayoría de las 366
  migraciones de este proyecto usan `def change do ... end` (DSL
  declarativo, reversible automático de Ecto) -- muy pocas usan `def
  up`/`def down` explícitos. Un detector que solo mirara "¿tiene `def
  down`?" fallaría para casi todo el histórico real -- por eso
  `clasificar/1` parsea el AST de `change/0` (`Code.string_to_quoted!/1`),
  nunca busca texto ni ejecuta la migración.

  Dos pasos separados a propósito (`clasificar/1` primero, verificación
  en vivo después) -- clasificar/1 es PURO (sin tocar ninguna base,
  testeable con fixtures reales del repo); `verificar_vacio?/2` y
  `verificar_columna_sin_uso?/4` SÍ tocan una base real (el mismo
  `MetadataApp.Repo` de donde corra este código -- en un release
  desplegado, eso YA apunta al Postgres del destino real, mismo
  mecanismo que usa `/app/bin/setup`; en test, la sandbox de siempre).
  """

  @doc """
  Clasifica una migración -- SOLO AST, nunca toca una base. Las
  operaciones `:candidata` todavía necesitan `verificar_vacio?/2` o
  `verificar_columna_sin_uso?/4` (paso 4 de design.md §6.2) antes de
  confirmarse como automáticas de verdad.

  `{:automatico, [operacion]}` | `{:manual, motivo, operacion_bloqueante}`
  """
  def clasificar(ruta_archivo_migracion) do
    ast = ruta_archivo_migracion |> File.read!() |> Code.string_to_quoted!()

    case buscar_change(ast) do
      nil ->
        {:manual, "Esta migración usa up/down explícitos en vez de change/0 -- no se puede analizar automáticamente.",
         %{tipo: :sin_change}}

      cuerpo ->
        cuerpo
        |> lista_de_statements()
        |> Enum.flat_map(&clasificar_statement/1)
        |> resolver()
    end
  end

  defp buscar_change(ast) do
    {_, encontrado} =
      Macro.prewalk(ast, nil, fn
        {:def, _, [{:change, _, _}, [do: cuerpo]]} = nodo, nil -> {nodo, cuerpo}
        nodo, acc -> {nodo, acc}
      end)

    encontrado
  end

  defp lista_de_statements({:__block__, _, statements}), do: statements
  defp lista_de_statements(statement), do: [statement]

  # create table(...) do ... end -- candidata, el CONTENIDO del bloque
  # (columnas nuevas de una tabla que todavía no existe) no importa acá,
  # lo único que se verifica en vivo es si la tabla resultante quedó
  # vacía (paso 4) -- por eso nunca se recorre `_cuerpo`.
  defp clasificar_statement({:create, _, [{:table, _, [tabla | _]}, [do: _cuerpo]]}) do
    [{:candidata, %{tipo: :tabla_nueva, tabla: tabla}}]
  end

  # alter table(...) do ... end -- acá SÍ importa cada operación interna
  defp clasificar_statement({:alter, _, [{:table, _, [tabla | _]}, [do: cuerpo]]}) do
    cuerpo
    |> lista_de_statements()
    |> Enum.flat_map(&clasificar_alter_interno(&1, tabla))
  end

  # create index(...) / create unique_index(...) -- SIN do (create/1, no
  # create/2) -- automática siempre, nunca toca datos existentes.
  defp clasificar_statement({:create, _, [{tipo_indice, _, _}]}) when tipo_indice in [:index, :unique_index] do
    [{:automatico, %{tipo: :indice}}]
  end

  defp clasificar_statement({:drop, _, [{:table, _, [tabla | _]}]}) do
    [{:manual, %{tipo: :drop_table, tabla: tabla, texto: "drop table(#{inspect(tabla)})"}}]
  end

  defp clasificar_statement(nodo) do
    [{:manual, %{tipo: :no_reconocido, texto: texto_literal(nodo)}}]
  end

  defp clasificar_alter_interno({:add, _, [campo, _tipo | resto]}, tabla) do
    default = extraer_opcion_default(resto)
    [{:candidata, %{tipo: :columna_nueva, tabla: tabla, campo: campo, default: default}}]
  end

  defp clasificar_alter_interno({:remove, _, _} = nodo, _tabla) do
    [{:manual, %{tipo: :remove, texto: texto_literal(nodo)}}]
  end

  defp clasificar_alter_interno({:modify, _, _} = nodo, _tabla) do
    [{:manual, %{tipo: :modify, texto: texto_literal(nodo)}}]
  end

  defp clasificar_alter_interno(nodo, _tabla) do
    [{:manual, %{tipo: :no_reconocido, texto: texto_literal(nodo)}}]
  end

  defp extraer_opcion_default([opts]) when is_list(opts), do: Keyword.get(opts, :default)
  defp extraer_opcion_default(_), do: nil

  # execute/1 se cuela en clasificar_statement/1 (no tiene head propio,
  # el catch-all de "no reconocido" ya lo marca manual) -- separado en
  # su propia cláusula solo para que el motivo diga "SQL crudo"
  # explícito en vez de "construcción no reconocida" (R10b pide texto
  # específico, no un mensaje genérico).
  defp texto_literal({:execute, _, _} = nodo), do: "SQL crudo: #{Macro.to_string(nodo) |> String.slice(0, 200)}"
  defp texto_literal(nodo), do: Macro.to_string(nodo) |> String.slice(0, 200)

  defp resolver(operaciones) do
    case Enum.find(operaciones, &match?({:manual, _}, &1)) do
      {:manual, %{texto: motivo} = operacion_bloqueante} ->
        {:manual, motivo, operacion_bloqueante}

      nil ->
        {:automatico, Enum.map(operaciones, fn {_candidata_o_automatico, op} -> op end)}
    end
  end

  @doc """
  Paso 4 de design.md §6.2 -- ¿la tabla `tabla` está vacía (0 filas) EN
  VIVO? Corre contra `repo` (default `MetadataApp.Repo`) -- en un
  release desplegado eso ya apunta al Postgres del destino real.
  """
  def verificar_vacio?(tabla, repo \\ MetadataApp.Repo) do
    %{rows: [[vacio]]} = Ecto.Adapters.SQL.query!(repo, ~s[SELECT NOT EXISTS(SELECT 1 FROM "#{tabla}")], [])
    vacio
  end

  @doc """
  Paso 4 -- ¿NINGUNA fila de `tabla` tiene un valor REAL en `campo`?
  "Real" = ni NULL ni exactamente `default` (el mismo `default:` que ya
  traía el `add/3` original, nunca adivinado). Sin `default` (nil), la
  única forma seria de "vacío" es NULL en todas.
  """
  def verificar_columna_sin_uso?(tabla, campo, default, repo \\ MetadataApp.Repo)

  def verificar_columna_sin_uso?(tabla, campo, nil, repo) do
    %{rows: [[sin_uso]]} =
      Ecto.Adapters.SQL.query!(repo, ~s[SELECT NOT EXISTS(SELECT 1 FROM "#{tabla}" WHERE "#{campo}" IS NOT NULL)], [])

    sin_uso
  end

  def verificar_columna_sin_uso?(tabla, campo, default, repo) do
    %{rows: [[sin_uso]]} =
      Ecto.Adapters.SQL.query!(
        repo,
        ~s[SELECT NOT EXISTS(SELECT 1 FROM "#{tabla}" WHERE "#{campo}" IS NOT NULL AND "#{campo}" != $1)],
        [default]
      )

    sin_uso
  end

  @doc "Cuántas filas tiene `tabla` -- alimenta el \"cuántas filas\" de R10b cuando verificar_vacio?/2 da false."
  def contar_filas(tabla, repo \\ MetadataApp.Repo) do
    %{rows: [[n]]} = Ecto.Adapters.SQL.query!(repo, ~s[SELECT COUNT(*) FROM "#{tabla}"], [])
    n
  end

  @doc "Cuántas filas de `tabla` tienen un valor REAL en `campo` (ni NULL ni el default) -- alimenta R10b cuando verificar_columna_sin_uso?/4 da false."
  def contar_filas_con_dato_real(tabla, campo, default, repo \\ MetadataApp.Repo)

  def contar_filas_con_dato_real(tabla, campo, nil, repo) do
    %{rows: [[n]]} = Ecto.Adapters.SQL.query!(repo, ~s[SELECT COUNT(*) FROM "#{tabla}" WHERE "#{campo}" IS NOT NULL], [])
    n
  end

  def contar_filas_con_dato_real(tabla, campo, default, repo) do
    %{rows: [[n]]} =
      Ecto.Adapters.SQL.query!(repo, ~s[SELECT COUNT(*) FROM "#{tabla}" WHERE "#{campo}" IS NOT NULL AND "#{campo}" != $1], [default])

    n
  end

  @doc """
  Clasifica el CONJUNTO de migraciones de `rutas` como uno solo (Grupo H,
  design.md §6.3 paso 1-2) -- una sola manual (a nivel AST o en la
  verificación en vivo) vuelve manual TODO el conjunto, corto-circuito
  antes de tocar la base si ya hay una manual a nivel AST.

  `{:automatico, [operacion]}` | `{:manual, motivo, operacion_bloqueante}`
  """
  def clasificar_conjunto(rutas, repo \\ MetadataApp.Repo) do
    resultados_ast = Enum.map(rutas, &clasificar/1)

    case Enum.find(resultados_ast, &match?({:manual, _, _}, &1)) do
      {:manual, _, _} = manual ->
        manual

      nil ->
        candidatas = Enum.flat_map(resultados_ast, fn {:automatico, ops} -> ops end)
        verificar_en_vivo(candidatas, repo)
    end
  end

  defp verificar_en_vivo(candidatas, repo) do
    Enum.find_value(candidatas, {:automatico, candidatas}, &candidata_insegura(&1, repo))
  end

  defp candidata_insegura(%{tipo: :tabla_nueva, tabla: tabla} = op, repo) do
    if verificar_vacio?(tabla, repo) do
      nil
    else
      n = contar_filas(tabla, repo)
      motivo = "La tabla \"#{tabla}\" ya tiene #{n} fila(s) con datos reales -- no se puede revertir automático."
      {:manual, motivo, Map.merge(op, %{motivo_vivo: :tabla_con_filas, filas: n})}
    end
  end

  defp candidata_insegura(%{tipo: :columna_nueva, tabla: tabla, campo: campo, default: default} = op, repo) do
    if verificar_columna_sin_uso?(tabla, campo, default, repo) do
      nil
    else
      n = contar_filas_con_dato_real(tabla, campo, default, repo)
      motivo = "La columna \"#{tabla}.#{campo}\" tiene #{n} fila(s) con datos reales -- no se puede revertir automático."
      {:manual, motivo, Map.merge(op, %{motivo_vivo: :columna_con_datos, filas: n})}
    end
  end

  defp candidata_insegura(%{tipo: :indice}, _repo), do: nil

  @doc "Versión (el prefijo numérico del nombre de archivo, mismo formato que usa Ecto.Migrator) de una ruta de migración."
  def version_de(ruta) do
    ruta
    |> Path.basename()
    |> String.split("_", parts: 2)
    |> hd()
    |> String.to_integer()
  end
end
