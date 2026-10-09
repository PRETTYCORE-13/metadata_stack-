defmodule MetadataApp.ConsultasSql.ContenidoMigracionTest do
  # Hotfix 2026-10-05 (autorizado por el usuario, registrado en
  # SPEC-ADN-0510202601): la migración de una SQL View o de un Servicio
  # incrustaba el SQL con inspect/1, que trunca a 4096 caracteres y deja
  # "..." al final; con un SQL largo, la migración ya no compilaba.
  use ExUnit.Case, async: true

  alias MetadataApp.ConsultasSql

  # ~6 KB, con comillas, saltos de línea y llaves como un SQL real.
  defp sql_largo do
    renglones = for i <- 1..120, do: "  SELECT #{i} AS n, 'texto \"#{i}\"' AS t, '{}'::bigint[] AS l -- comentario #{i}"
    Enum.join(renglones, "\nUNION ALL\n")
  end

  # Compila el contenido y regresa los argumentos de cada `execute` de up/0.
  defp executes_de(contenido) do
    {:ok, ast} = Code.string_to_quoted(contenido)

    {_, encontrados} =
      Macro.prewalk(ast, [], fn
        {:execute, _, [sql]} = nodo, acc when is_binary(sql) -> {nodo, [sql | acc]}
        nodo, acc -> {nodo, acc}
      end)

    Enum.reverse(encontrados)
  end

  test "la migración de una SQL View lleva el SQL completo, aunque pase de 4 KB" do
    sql = sql_largo()
    assert byte_size(sql) > 4096

    contenido = ConsultasSql.contenido_migracion("pty_sql_prueba_larga", sql, "20261005000000")

    refute contenido =~ ~s(...")
    assert "CREATE VIEW pty_sql_prueba_larga AS " <> sql in executes_de(contenido)
  end

  test "la migración de un Servicio lleva la función completa, aunque pase de 4 KB" do
    crear = "CREATE FUNCTION pty_sql_prueba_larga() RETURNS TABLE (n bigint) AS $$\n" <> sql_largo() <> "\n$$ LANGUAGE sql STABLE"

    contenido = ConsultasSql.contenido_migracion_funcion("pty_sql_prueba_larga", crear, "20261005000000")

    refute contenido =~ ~s(...")
    assert crear in executes_de(contenido)
  end
end
