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
end
