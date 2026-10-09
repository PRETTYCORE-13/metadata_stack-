defmodule MetadataAppWeb.GridEditableFormatoTest do
  @moduledoc """
  SPEC-SYS-0810202602 R11: la metadata de columnas del grid de renglones
  dice si la columna tiene formato de captura número/moneda, para que el
  hook GridEditable formatee también una columna capturable.
  """
  use ExUnit.Case, async: true

  alias MetadataAppWeb.GridEditableComponents

  defp columna(props), do: %{schema_context_field: "cantidad", schema_context_properties: Map.merge(%{"tipo" => "decimal"}, props)}

  test "con formato número: formato true y sus decimales" do
    [col] = GridEditableComponents.columnas_para_js([columna(%{"formato_captura" => %{"habilitada" => true, "modo" => "numero", "decimales" => 2}})])
    assert %{formato: true, decimales: 2, moneda: false} = col
  end

  test "con formato moneda: formato y moneda true" do
    [col] = GridEditableComponents.columnas_para_js([columna(%{"formato_captura" => %{"habilitada" => true, "modo" => "moneda", "decimales" => 3}})])
    assert %{formato: true, decimales: 3, moneda: true} = col
  end

  test "sin formato o deshabilitado: formato false" do
    [sin, deshabilitado] =
      GridEditableComponents.columnas_para_js([
        columna(%{}),
        columna(%{"formato_captura" => %{"habilitada" => false, "modo" => "numero", "decimales" => 2}})
      ])

    assert %{formato: false} = sin
    assert %{formato: false} = deshabilitado
  end

  describe "operación del pie (R13, Total en renglones)" do
    test "sin configurar suma; promedio y ninguno según el campo" do
      [sin, promedio, ninguno] =
        GridEditableComponents.columnas_para_js([
          columna(%{}),
          columna(%{"total_renglones" => "promedio"}),
          columna(%{"total_renglones" => "ninguno"})
        ])

      assert %{activo: true, operacion: "suma"} = sin.resumen
      assert %{activo: true, operacion: "promedio"} = promedio.resumen
      assert %{activo: false} = ninguno.resumen
    end

    test "ResumenRenglones aplica la misma regla" do
      renglones = [%{"a" => "2", "b" => "2", "c" => "2"}, %{"a" => "4", "b" => "4", "c" => "4"}]

      col = fn campo, op ->
        %{schema_context_field: campo, schema_context_properties: %{"tipo" => "decimal", "total_renglones" => op}}
      end

      resumen = MetadataApp.ResumenRenglones.calcular(renglones, [col.("a", "suma"), col.("b", "promedio"), col.("c", "ninguno")])

      assert resumen["a"].valor == 6.0
      assert resumen["b"].valor == 3.0
      refute Map.has_key?(resumen, "c")
    end
  end
end
