defmodule MetadataAppWeb.FichaLiveNumeroSoloLecturaTest do
  @moduledoc """
  Campo numérico de solo lectura del encabezado de la Ficha con formato de
  captura número/moneda: se muestra igual que en los renglones
  (SPEC-SYS-0810202602 R6); sin formato, el valor pasa tal cual.
  """
  use ExUnit.Case, async: true

  alias MetadataAppWeb.FichaLive

  defp props(formato), do: %{"tipo" => "decimal", "formato_captura" => formato}

  @moneda %{"habilitada" => true, "modo" => "moneda", "decimales" => 2, "simbolo" => "$", "separador_miles" => true}

  test "moneda: símbolo, separador de miles y los decimales configurados" do
    assert FichaLive.numero_con_formato_captura(Decimal.new("1234567.550000"), props(@moneda)) == "$1,234,567.55"
  end

  test "número: los decimales configurados" do
    formato = %{"habilitada" => true, "modo" => "numero", "decimales" => 3}
    assert FichaLive.numero_con_formato_captura(Decimal.new("12.5"), props(formato)) == "12.500"
    assert FichaLive.numero_con_formato_captura(7, props(formato)) == "7.000"
  end

  test "sin formato, deshabilitado o sin valor: pasa tal cual" do
    assert FichaLive.numero_con_formato_captura(5, %{"tipo" => "integer"}) == 5
    assert FichaLive.numero_con_formato_captura(5, props(%{@moneda | "habilitada" => false})) == 5
    assert FichaLive.numero_con_formato_captura(nil, props(@moneda)) == nil
  end
end
