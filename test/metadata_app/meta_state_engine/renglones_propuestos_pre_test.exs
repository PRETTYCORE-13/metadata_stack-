defmodule MetadataApp.MetaStateEngine.RenglonesPropuestosPreTest do
  # SPEC-SYS-0510202601 §2.3 (R7-R9): la regla PRE del encabezado recibe
  # contexto["renglones_propuestos"] en alta, transición, guardar y
  # descubrimiento de botones. Escenario: MetadataApp.PedidoMultinivelFixtures
  # y la regla de prueba test/support/reglas_pedido_prueba_multinivel.ex.
  use MetadataApp.DataCase, async: true

  import MetadataApp.PedidoMultinivelFixtures

  alias MetadataApp.{MetaStateEngine, Repo}
  alias MetadataApp.BusinessProcessBuilder.CatalogoGenerico
  alias MetadataApp.MetaBusinessProcess.Catalogos.{PedidoPruebaMultinivel, PartidasPruebaMultinivel}

  setup do
    registrar_metadata!()
    :ok
  end

  defp conteos do
    {Repo.aggregate(PedidoPruebaMultinivel, :count), Repo.aggregate(PartidasPruebaMultinivel, :count)}
  end

  defp vistos(propuestos), do: Enum.map(propuestos[partidas()], &{&1["tipo"], &1["registro"].partidas_prueba_multinivel_producto})

  # Pedido ya creado, sin los avisos de la regla que dejó su propia alta.
  defp pedido_con_partidas!(folio, productos) do
    pedido = pedido!(folio, productos)
    flush_mensajes()
    pedido
  end

  defp flush_mensajes do
    receive do
      {:pre_pedido, _, _} -> flush_mensajes()
    after
      0 -> :ok
    end
  end

  describe "alta con renglones (dar_de_alta/5)" do
    test "la regla del encabezado ve los nuevos y el alta se guarda" do
      assert {:ok, pedido} = alta("P-1", ["Tornillos", "Tuercas"])

      assert_received {:pre_pedido, "alta", propuestos}
      assert vistos(propuestos) == [{"nuevo", "Tornillos"}, {"nuevo", "Tuercas"}]
      assert productos_en_base(pedido.id) == ["Tornillos", "Tuercas"]
    end

    test "un rechazo por renglones no guarda nada (R9)" do
      antes = conteos()

      assert {:error, _} = alta("P-2", ["Tornillos", "PROHIBIDO"])
      assert conteos() == antes
    end
  end

  describe "guardar sin renglones editados (CatalogoGenerico.actualizar/5)" do
    test "la regla ve existentes y nuevos; un nuevo prohibido se rechaza" do
      pedido = pedido_con_partidas!("P-3", ["Tornillos"])

      assert {:error, _} =
               CatalogoGenerico.actualizar(pedido, :sistema, %{}, %{}, renglones_nuevos: %{partidas() => [%{producto() => "PROHIBIDO"}]})

      assert_received {:pre_pedido, "guardar", propuestos}
      assert vistos(propuestos) == [{"existente", "Tornillos"}, {"nuevo", "PROHIBIDO"}]
      assert productos_en_base(pedido.id) == ["Tornillos"]
    end
  end

  describe "transición con renglones (ejecutar_transicion/4)" do
    test "un editado prohibido se rechaza y el renglón no cambia (R9)" do
      pedido = pedido_con_partidas!("P-4", ["Tornillos"])

      assert {:error, _} =
               MetaStateEngine.ejecutar_transicion(pedido, "guardar", %{}, renglones: %{partidas() => [%{"renglon_id" => 1, producto() => "PROHIBIDO"}]})

      assert_received {:pre_pedido, "guardar", propuestos}
      assert vistos(propuestos) == [{"editado", "PROHIBIDO"}]
      assert productos_en_base(pedido.id) == ["Tornillos"]
    end

    test "quitar la única partida de un pedido REQ- se rechaza" do
      pedido = pedido_con_partidas!("REQ-5", ["Tornillos"])

      assert {:error, _} = MetaStateEngine.ejecutar_transicion(pedido, "guardar", %{}, renglones_quitados: %{partidas() => [1]})

      assert_received {:pre_pedido, "guardar", propuestos}
      assert vistos(propuestos) == [{"quitado", "Tornillos"}]
    end

    test "mezcla: la regla ve editado, quitado y nuevo, cada uno con su tipo" do
      pedido = pedido_con_partidas!("P-6", ["Tornillos", "Tuercas"])

      assert {:ok, _} =
               MetaStateEngine.ejecutar_transicion(pedido, "guardar", %{},
                 renglones: %{partidas() => [%{"renglon_id" => 1, producto() => "Tornillos M8"}]},
                 renglones_quitados: %{partidas() => [2]},
                 renglones_nuevos: %{partidas() => [%{producto() => "Rondanas"}]}
               )

      assert_received {:pre_pedido, "guardar", propuestos}
      assert vistos(propuestos) == [{"editado", "Tornillos M8"}, {"quitado", "Tuercas"}, {"nuevo", "Rondanas"}]
      # ejecutar_transicion/4 solo escribe los editados; crear y quitar le toca al caller (§2.4).
      assert productos_en_base(pedido.id) == ["Tornillos M8", "Tuercas"]
    end
  end

  describe "descubrimiento de botones (transiciones_disponibles/2, D6)" do
    test "la regla ve los existentes y deshabilita la transición con su razón" do
      pedido = pedido_con_partidas!("P-7", ["BLOQUEA_BAJA"])

      baja = pedido |> MetaStateEngine.transiciones_disponibles() |> Enum.find(&(&1.accion == "baja"))

      assert %{disponible: false, razones: [%{mensaje: "una partida impide la baja"}]} = baja
    end
  end
end
