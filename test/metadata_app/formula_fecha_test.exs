defmodule MetadataApp.FormulaFechaTest do
  use ExUnit.Case, async: true

  alias MetadataApp.FormulaFecha

  # Fecha fija para que los tests no dependan del día en que corren.
  @hoy ~D[2026-03-15]

  describe "bases" do
    test "\"actual\" es hoy" do
      assert FormulaFecha.parsear("actual", @hoy) == {:ok, @hoy}
    end

    test "\"primer_dia_mes\" es el 1° del mes de hoy" do
      assert FormulaFecha.parsear("primer_dia_mes", @hoy) == {:ok, ~D[2026-03-01]}
    end

    test "\"primer_dia_anio\" es el 1/1 del año de hoy" do
      assert FormulaFecha.parsear("primer_dia_anio", @hoy) == {:ok, ~D[2026-01-01]}
    end

    test "una fecha literal ISO se usa tal cual" do
      assert FormulaFecha.parsear("2025-12-24", @hoy) == {:ok, ~D[2025-12-24]}
    end

    test "una base inválida da error, no crashea" do
      assert {:error, mensaje} = FormulaFecha.parsear("no_existe", @hoy)
      assert mensaje =~ "Base inválida"
    end
  end

  describe "offsets" do
    test "resta días" do
      assert FormulaFecha.parsear("actual - 5 dias", @hoy) == {:ok, ~D[2026-03-10]}
    end

    test "suma meses" do
      assert FormulaFecha.parsear("primer_dia_mes + 2 meses", @hoy) == {:ok, ~D[2026-05-01]}
    end

    test "resta meses" do
      assert FormulaFecha.parsear("actual - 3 meses", @hoy) == {:ok, ~D[2025-12-15]}
    end

    test "resta años" do
      assert FormulaFecha.parsear("actual - 1 anio", @hoy) == {:ok, ~D[2025-03-15]}
    end

    test "acepta \"año\"/\"años\" con tilde igual que \"anio\"/\"anios\"" do
      assert FormulaFecha.parsear("actual - 1 año", @hoy) == {:ok, ~D[2025-03-15]}
      assert FormulaFecha.parsear("actual - 2 años", @hoy) == {:ok, ~D[2024-03-15]}
    end

    test "encadena varios offsets" do
      assert FormulaFecha.parsear("primer_dia_anio + 6 meses - 10 dias", @hoy) == {:ok, ~D[2026-06-21]}
    end

    test "clampea al último día real del mes destino (31 ene - 1 mes -> 28/29 feb)" do
      assert FormulaFecha.parsear("2026-01-31 - 1 mes", @hoy) == {:ok, ~D[2025-12-31]}
      assert FormulaFecha.parsear("2026-03-31 - 1 mes", @hoy) == {:ok, ~D[2026-02-28]}
    end
  end

  describe "errores" do
    test "texto vacío o nil da error" do
      assert {:error, _} = FormulaFecha.parsear("", @hoy)
      assert {:error, _} = FormulaFecha.parsear(nil, @hoy)
    end

    test "unidad inválida da error" do
      assert {:error, mensaje} = FormulaFecha.parsear("actual - 3 semanas", @hoy)
      assert mensaje =~ "No se entiende"
    end

    test "cantidad no numérica da error" do
      assert {:error, _} = FormulaFecha.parsear("actual - x meses", @hoy)
    end

    test "signo sin cantidad/unidad completa da error" do
      assert {:error, _} = FormulaFecha.parsear("actual -", @hoy)
    end

    test "nunca ejecuta código: un intento de inyección Elixir da error de parseo, no una excepción" do
      assert {:error, _} = FormulaFecha.parsear("System.cmd(\"ls\", [])", @hoy)
    end
  end
end
