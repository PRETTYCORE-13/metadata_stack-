defmodule MetadataApp.Dsd.FrecuenciaVisitasTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias MetadataApp.Dsd.FrecuenciaVisitas, as: Motor

  describe "aplica?/3 -- casos unitarios (seeds típicos de Fase 1)" do
    test "diaria exc. domingo: nunca aplica en domingo, siempre en el resto" do
      vigencia = vigencia(~D[2026-01-05], nil, ~D[2026-01-05])
      frecuencia = frecuencia("diaria", 1, "1,2,3,4,5,6")

      for fecha <- Date.range(~D[2026-01-05], ~D[2026-01-18]) do
        esperado = Date.day_of_week(fecha) != 7
        assert Motor.aplica?(vigencia, frecuencia, fecha) == esperado, "fecha #{fecha}"
      end
    end

    test "semanal L-Mi-V" do
      vigencia = vigencia(~D[2026-01-05], nil, ~D[2026-01-05])
      frecuencia = frecuencia("semanal", 1, "1,3,5")

      dias_programados =
        Date.range(~D[2026-01-05], ~D[2026-01-11])
        |> Enum.filter(&Motor.aplica?(vigencia, frecuencia, &1))
        |> Enum.map(&Date.day_of_week/1)

      assert dias_programados == [1, 3, 5]
    end

    test "quincenal miércoles: alterna semanas desde el ancla" do
      ancla = ~D[2026-01-07]
      vigencia = vigencia(~D[2026-01-01], nil, ancla)
      frecuencia = frecuencia("quincenal", 2, "3")

      assert Motor.aplica?(vigencia, frecuencia, ~D[2026-01-07])
      refute Motor.aplica?(vigencia, frecuencia, ~D[2026-01-14])
      assert Motor.aplica?(vigencia, frecuencia, ~D[2026-01-21])
      refute Motor.aplica?(vigencia, frecuencia, ~D[2026-01-28])
    end

    test "mensual día 1" do
      vigencia = vigencia(~D[2026-01-01], nil, ~D[2026-01-01])
      frecuencia = frecuencia("mensual", 1, "1")

      assert Motor.aplica?(vigencia, frecuencia, ~D[2026-02-01])
      assert Motor.aplica?(vigencia, frecuencia, ~D[2026-03-01])
      refute Motor.aplica?(vigencia, frecuencia, ~D[2026-02-15])
    end

    test "anual: solo coincide mes/día del ancla" do
      vigencia = vigencia(~D[2026-01-01], nil, ~D[2026-01-15])
      frecuencia = frecuencia("anual", 1, nil)

      assert Motor.aplica?(vigencia, frecuencia, ~D[2027-01-15])
      refute Motor.aplica?(vigencia, frecuencia, ~D[2026-06-15])
    end

    test "fuera de [vigente_desde, vigente_hasta] nunca aplica" do
      vigencia = vigencia(~D[2026-03-01], ~D[2026-03-31], ~D[2026-03-01])
      frecuencia = frecuencia("diaria", 1, "1,2,3,4,5,6,7")

      refute Motor.aplica?(vigencia, frecuencia, ~D[2026-02-28])
      refute Motor.aplica?(vigencia, frecuencia, ~D[2026-04-01])
    end
  end

  describe "clientes_programados_en_fecha/3 y carga_por_dia/4" do
    test "resuelve el historial de vigencias de cada cliente" do
      frecuencias_por_id = %{1 => frecuencia("diaria", 1, "1,2,3,4,5,6,7")}

      vigencias_por_cliente = %{
        "a" => [vigencia_con_id(~D[2026-01-01], nil, ~D[2026-01-01], 1)],
        "b" => [vigencia_con_id(~D[2026-02-01], nil, ~D[2026-02-01], 1)]
      }

      assert Motor.clientes_programados_en_fecha(vigencias_por_cliente, frecuencias_por_id, ~D[2026-01-15]) == ["a"]

      carga = Motor.carga_por_dia(vigencias_por_cliente, frecuencias_por_id, ~D[2026-01-15], ~D[2026-02-15])
      assert carga[~D[2026-01-15]] == 1
      assert carga[~D[2026-02-15]] == 2
    end
  end

  # -- Generadores --------------------------------------------------------

  defp fecha_generator do
    gen all year <- integer(2024..2028), month <- integer(1..12), day <- integer(1..28) do
      Date.new!(year, month, day)
    end
  end

  # Bug real (2026-08-27, CI): max_length 5 sobre un dominio de solo 6
  # valores posibles (1..6) deja muy poco margen -- StreamData.uniq_list_of/2
  # rechaza-y-reintenta para lograr unicidad, y cerca del límite del
  # dominio a veces agota sus reintentos antes de completar la lista
  # (StreamData.TooManyDuplicatesError, visto real en CI: "too many (10)
  # non-unique elements were generated consecutively"). max_length 4 sigue
  # ejercitando selecciones multi-día de sobra, con margen real contra el
  # dominio de 6.
  defp selector_dias_sin_domingo_generator do
    gen all dias <- uniq_list_of(integer(1..6), min_length: 1, max_length: 4) do
      Enum.join(dias, ",")
    end
  end

  defp frecuencia_generator do
    gen all base <- member_of(["diaria", "semanal", "quincenal", "mensual", "anual"]),
            intervalo <- integer(1..4),
            dia_mes <- integer(1..28) do
      selector =
        case base do
          "mensual" -> to_string(dia_mes)
          "anual" -> nil
          _ -> Enum.join(Enum.take_random(1..7, Enum.random(1..7)) |> Enum.uniq(), ",")
        end

      frecuencia(base, intervalo, selector)
    end
  end

  defp vigencia(desde, hasta, ancla), do: %{
    pty_dsd_cs_vigencias_frec_vigente_desde: desde,
    pty_dsd_cs_vigencias_frec_vigente_hasta: hasta,
    pty_dsd_cs_vigencias_frec_fecha_ancla: ancla
  }

  defp vigencia_con_id(desde, hasta, ancla, frecuencia_id) do
    Map.put(vigencia(desde, hasta, ancla), :pty_dsd_cs_vigencias_frec_frecuencia, frecuencia_id)
  end

  defp frecuencia(base, intervalo, selector_dias), do: %{
    pty_dsd_cs_frecuencias_frecuencia_base: base,
    pty_dsd_cs_frecuencias_intervalo: intervalo,
    pty_dsd_cs_frecuencias_selector_dias: selector_dias,
    pty_dsd_cs_frecuencias_ancla_default: nil
  }

  # -- Propiedades (las 5 mínimas especificadas) ---------------------------

  property "(a) toda pareja de fechas consecutivas de una regla quincenal (un solo día) dista exactamente 14 días" do
    check all dia_semana <- integer(1..7),
              ancla <- fecha_generator(),
              max_runs: 30 do
      vigencia = vigencia(ancla, nil, ancla)
      frecuencia = frecuencia("quincenal", 2, to_string(dia_semana))

      fechas =
        Date.range(ancla, Date.add(ancla, 120))
        |> Enum.filter(&Motor.aplica?(vigencia, frecuencia, &1))

      fechas
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.each(fn [f1, f2] -> assert Date.diff(f2, f1) == 14 end)
    end
  end

  property "(b) ningún selector que excluye domingo programa un domingo" do
    check all base <- member_of(["diaria", "semanal", "quincenal"]),
              intervalo <- integer(1..3),
              selector <- selector_dias_sin_domingo_generator(),
              desde <- fecha_generator(),
              max_runs: 50 do
      vigencia = vigencia(desde, nil, desde)
      frecuencia = frecuencia(base, intervalo, selector)

      Date.range(desde, Date.add(desde, 60))
      |> Enum.each(fn fecha ->
        if Motor.aplica?(vigencia, frecuencia, fecha) do
          assert Date.day_of_week(fecha) != 7
        end
      end)
    end
  end

  property "(c) ninguna fecha programada cae fuera de su vigencia" do
    check all desde <- fecha_generator(),
              dias_vigencia <- integer(1..90),
              frecuencia <- frecuencia_generator(),
              max_runs: 50 do
      hasta = Date.add(desde, dias_vigencia)
      vigencia = vigencia(desde, hasta, desde)

      Date.range(Date.add(desde, -10), Date.add(hasta, 10))
      |> Enum.each(fn fecha ->
        if Motor.aplica?(vigencia, frecuencia, fecha) do
          assert Date.compare(fecha, desde) != :lt
          assert Date.compare(fecha, hasta) != :gt
        end
      end)
    end
  end

  property "(d) un cambio de vigencia nunca produce programación antes de su fecha de efecto" do
    check all fecha_corte <- fecha_generator(),
              dias_anterior <- integer(30..200),
              frecuencia_anterior <- frecuencia_generator(),
              frecuencia_nueva <- frecuencia_generator(),
              max_runs: 30 do
      desde_anterior = Date.add(fecha_corte, -dias_anterior)
      hasta_anterior = Date.add(fecha_corte, -1)

      vigencia_anterior =
        vigencia(desde_anterior, hasta_anterior, desde_anterior)
        |> Map.put(:pty_dsd_cs_vigencias_frec_frecuencia, :anterior)

      vigencia_nueva =
        vigencia(fecha_corte, nil, fecha_corte)
        |> Map.put(:pty_dsd_cs_vigencias_frec_frecuencia, :nueva)

      frecuencias_por_id = %{anterior: frecuencia_anterior, nueva: frecuencia_nueva}

      fechas =
        Motor.fechas_programadas(
          [vigencia_anterior, vigencia_nueva],
          frecuencias_por_id,
          desde_anterior,
          Date.add(fecha_corte, 20)
        )

      fechas
      |> Enum.filter(&Motor.aplica?(vigencia_nueva, frecuencia_nueva, &1))
      |> Enum.each(fn fecha -> assert Date.compare(fecha, fecha_corte) != :lt end)
    end
  end

  property "(e) para cualquier fecha, a lo sumo una vigencia (no solapada) del cliente aplica" do
    check all n <- integer(1..5),
              primer_desde <- fecha_generator(),
              duraciones <- list_of(integer(1..60), length: n),
              max_runs: 30 do
      vigencias =
        Enum.reduce(duraciones, {primer_desde, []}, fn dias, {desde, acc} ->
          hasta = Date.add(desde, dias)
          {Date.add(hasta, 1), [vigencia(desde, hasta, desde) | acc]}
        end)
        |> elem(1)
        |> Enum.reverse()

      ultima_hasta = List.last(vigencias).pty_dsd_cs_vigencias_frec_vigente_hasta

      Date.range(Date.add(primer_desde, -5), Date.add(ultima_hasta, 5))
      |> Enum.each(fn fecha ->
        coincidencias = Enum.count(vigencias, &Motor.vigente_en?(&1, fecha))
        assert coincidencias <= 1
      end)
    end
  end
end
