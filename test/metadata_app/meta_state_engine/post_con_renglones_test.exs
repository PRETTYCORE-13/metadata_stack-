defmodule MetadataApp.MetaStateEngine.PostConRenglonesTest do
  # SPEC-SYS-0710202602: la regla POST del encabezado corre al final, cuando
  # sus renglones nuevos, editados y quitados ya están guardados. Escenario:
  # MetadataApp.PedidoMultinivelFixtures y la regla de prueba
  # test/support/reglas_post_pedido_prueba_multinivel.ex.
  # async: false -- registra la metadata de pedido_prueba_multinivel (mismo
  # motivo que renglones_propuestos_pre_test.exs).
  use MetadataApp.DataCase, async: false

  import MetadataApp.PedidoMultinivelFixtures

  alias MetadataApp.{MetaImportacionDatos, MetaStateEngine, Renglones, Repo}
  alias MetadataApp.BusinessProcessBuilder.CatalogoGenerico
  alias MetadataApp.MetaSchema.PlantillaImportacion

  alias MetadataApp.MetaBusinessProcess.Catalogos.{
    PedidoPruebaMultinivel,
    PartidasPruebaMultinivel
  }

  setup do
    %{maestro: registrar_metadata!()}
  end

  defp conteos do
    {Repo.aggregate(PedidoPruebaMultinivel, :count),
     Repo.aggregate(PartidasPruebaMultinivel, :count)}
  end

  # Pedido ya creado, sin los avisos que dejó su propia alta.
  defp pedido_limpio!(folio, productos) do
    pedido = pedido!(folio, productos)
    flush_mensajes()
    pedido
  end

  defp flush_mensajes do
    receive do
      {:pre_pedido, _, _} -> flush_mensajes()
      {:post_pedido, _, _} -> flush_mensajes()
    after
      0 -> :ok
    end
  end

  # Lo mismo que escriben la Ficha y la importación, por la opción del motor.
  defp escribir(pedido, nuevos, quitados) do
    fn _registro ->
      with {:ok, creados} <- Renglones.crear_todos(maestro(), pedido.id, nuevos),
           {:ok, eliminados} <- Renglones.eliminar_todos(maestro(), pedido.id, quitados) do
        {:ok, {creados, eliminados}}
      end
    end
  end

  defp productos_vistos(partidas),
    do: Enum.map(partidas, fn {_id, _renglon, producto} -> producto end)

  describe "alta con renglones (R1, R2)" do
    test "el POST ve las partidas ya creadas, con id y renglon_id" do
      assert {:ok, _pedido} = alta("A-1", ["Tornillos", "Tuercas"])

      assert_received {:post_pedido, "alta", partidas}
      assert [{id1, 1, "Tornillos"}, {id2, 2, "Tuercas"}] = partidas
      assert is_integer(id1) and is_integer(id2)
    end
  end

  describe "guardar sin renglones editados (R1, R2, R7)" do
    test "agregar y quitar: el POST ve el resultado final", %{maestro: _} do
      pedido = pedido_limpio!("G-1", ["Tornillos", "Tuercas"])
      nuevos = %{partidas() => [%{producto() => "Rondanas"}]}
      quitados = %{partidas() => [1]}

      assert {:ok, _} =
               CatalogoGenerico.actualizar(pedido, :sistema, %{}, %{},
                 renglones_nuevos: nuevos,
                 renglones_quitados: quitados,
                 escribir_renglones: escribir(pedido, nuevos, quitados)
               )

      assert_received {:pre_pedido, "guardar", _}
      assert_received {:post_pedido, "guardar", partidas}
      assert productos_vistos(partidas) == ["Tuercas", "Rondanas"]
      assert productos_en_base(pedido.id) == ["Tuercas", "Rondanas"]
    end
  end

  describe "transición con renglones editados (R1, R2, R5)" do
    test "el POST ve el editado con su valor nuevo, el nuevo y no el quitado" do
      pedido = pedido_limpio!("T-1", ["Tornillos", "Tuercas"])
      nuevos = %{partidas() => [%{producto() => "Rondanas"}]}
      quitados = %{partidas() => [2]}

      assert {:ok, _} =
               MetaStateEngine.ejecutar_transicion(pedido, "guardar", %{},
                 renglones: %{partidas() => [%{"renglon_id" => 1, producto() => "Tornillos M8"}]},
                 renglones_nuevos: nuevos,
                 renglones_quitados: quitados,
                 escribir_renglones: escribir(pedido, nuevos, quitados)
               )

      assert_received {:post_pedido, "guardar", partidas}
      assert productos_vistos(partidas) == ["Tornillos M8", "Rondanas"]
      assert productos_en_base(pedido.id) == ["Tornillos M8", "Rondanas"]
    end
  end

  describe "el POST escribe (R3)" do
    test "en el alta: marca cada partida y el encabezado" do
      assert {:ok, pedido} = alta("POST-ESCRIBE", ["Tornillos", "Tuercas"])

      assert Repo.get!(PedidoPruebaMultinivel, pedido.id).pedido_prueba_multinivel_folio ==
               "POST-ESCRIBE (2)"

      assert productos_en_base(pedido.id) == ["Tornillos*", "Tuercas*"]
    end

    test "al guardar con una partida nueva: la nueva también queda marcada" do
      pedido = pedido_limpio!("POST-ESCRIBE", ["Tornillos"])
      nuevos = %{partidas() => [%{producto() => "Rondanas"}]}

      assert {:ok, _} =
               CatalogoGenerico.actualizar(pedido, :sistema, %{}, %{},
                 renglones_nuevos: nuevos,
                 escribir_renglones: escribir(pedido, nuevos, %{})
               )

      assert Repo.get!(PedidoPruebaMultinivel, pedido.id).pedido_prueba_multinivel_folio ==
               "POST-ESCRIBE (2)"

      assert productos_en_base(pedido.id) == ["Tornillos**", "Rondanas*"]
    end
  end

  describe "el POST falla (R4)" do
    test "en el alta no queda ni el pedido ni sus partidas" do
      antes = conteos()

      assert {:error, {:postcondicion_fallida, "falla de prueba del POST"}} =
               alta("POST-FALLA", ["Tornillos"])

      assert conteos() == antes
    end

    test "al guardar no cambia el encabezado ni se crean o quitan partidas" do
      pedido = pedido_limpio!("G-2", ["Tornillos", "Tuercas"])
      nuevos = %{partidas() => [%{producto() => "Rondanas"}]}
      quitados = %{partidas() => [1]}

      assert {:error, {:postcondicion_fallida, _}} =
               CatalogoGenerico.actualizar(pedido, :sistema, %{folio() => "POST-FALLA"}, %{},
                 renglones_nuevos: nuevos,
                 renglones_quitados: quitados,
                 escribir_renglones: escribir(pedido, nuevos, quitados)
               )

      assert Repo.get!(PedidoPruebaMultinivel, pedido.id).pedido_prueba_multinivel_folio == "G-2"
      assert productos_en_base(pedido.id) == ["Tornillos", "Tuercas"]
    end

    test "un error al escribir los renglones se regresa tal cual y no guarda nada" do
      pedido = pedido_limpio!("G-3", ["Tornillos"])
      falla = fn _registro -> {:error, "no se pudo escribir"} end

      assert {:error, "no se pudo escribir"} =
               CatalogoGenerico.actualizar(pedido, :sistema, %{folio() => "G-3b"}, %{},
                 escribir_renglones: falla
               )

      assert Repo.get!(PedidoPruebaMultinivel, pedido.id).pedido_prueba_multinivel_folio == "G-3"
      refute_received {:post_pedido, _, _}
    end
  end

  describe "importación de un pedido existente (R6)" do
    test "el POST ve la partida nueva ya creada" do
      pedido = pedido_limpio!("I-1", ["Tornillos"])

      plantilla = %PlantillaImportacion{
        meta_schema_header_id:
          MetadataApp.BusinessProcessBuilder.MetaSchemaContext.obtener_header_por_nombre(
            maestro()
          ).id,
        definicion: %{
          "campos" => [%{"campo" => folio()}],
          "campo_identificador_encabezado" => folio(),
          "detalles" => [
            %{"catalogo" => partidas(), "activo" => true, "campos" => [%{"campo" => producto()}]}
          ]
        }
      }

      filas = %{
        "encabezado" => [%{"Folio" => "I-1"}],
        "detalles" => %{partidas() => [%{"Folio" => "I-1", "Producto" => "Rondanas"}]}
      }

      assert [%{resultado: resultado}] = MetaImportacionDatos.ejecutar(plantilla, :sistema, filas)
      refute resultado == :error

      assert_received {:post_pedido, "guardar", partidas}
      assert productos_vistos(partidas) == ["Tornillos", "Rondanas"]
      assert productos_en_base(pedido.id) == ["Tornillos", "Rondanas"]
    end
  end

  describe "sin cambios de renglones (R9)" do
    test "guardar solo el encabezado: el POST ve las mismas partidas y no se tocan" do
      pedido = pedido_limpio!("S-1", ["Tornillos"])

      assert {:ok, actualizado} =
               CatalogoGenerico.actualizar(pedido, :sistema, %{folio() => "S-1b"}, %{})

      assert actualizado.pedido_prueba_multinivel_folio == "S-1b"
      assert_received {:post_pedido, "guardar", [{_, 1, "Tornillos"}]}
      assert productos_en_base(pedido.id) == ["Tornillos"]
    end
  end
end
