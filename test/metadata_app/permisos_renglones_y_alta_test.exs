defmodule MetadataApp.PermisosRenglonesYAltaTest do
  # SPEC-SYS-0810202601. Escenario: MetadataApp.PedidoMultinivelFixtures
  # (pedido_prueba_multinivel, estados Activo/Baja, permisos de detalle
  # completos en Activo y ninguno en Baja).
  # async: false -- registra la metadata de pedido_prueba_multinivel.
  use MetadataApp.DataCase, async: false

  import Ecto.Query
  import MetadataApp.AutenticacionFixtures
  import MetadataApp.PedidoMultinivelFixtures

  alias MetadataApp.{MetaEstadosAdmin, MetaStateEngine, Renglones, Repo}
  alias MetadataApp.BusinessProcessBuilder.{CatalogoGenerico, MetaSchemaContext}
  alias MetadataApp.MetaSchema.Transicion
  alias MetadataApp.MetaBusinessProcess.Catalogos.{PedidoPruebaMultinivel, SubcategoriasPrueba}

  setup do
    %{maestro: registrar_metadata!()}
  end

  defp en_baja!(pedido) do
    {:ok, baja} = MetaStateEngine.ejecutar_transicion(pedido, "baja", %{})
    baja
  end

  defp transicion!(maestro, accion),
    do:
      Repo.one!(
        from t in Transicion,
          where: t.meta_schema_header_id == ^maestro.id and t.accion == ^accion
      )

  describe "permisos de renglones con el estado del maestro (R1-R3)" do
    test "un pedido en Baja cuyas partidas siguen en Activo no deja quitarlas" do
      pedido = pedido!("P-1", ["Tornillos"]) |> en_baja!()

      assert {:error, mensaje} =
               Renglones.eliminar_todos(maestro(), pedido.id, %{partidas() => [1]})

      assert mensaje =~ "En el estado Baja no se pueden quitar renglones"
      assert productos_en_base(pedido.id) == ["Tornillos"]
    end

    test "tampoco por el camino de la Ficha (escribir_renglones sin transición guardar)" do
      pedido = pedido!("P-2", ["Tornillos"]) |> en_baja!()
      quitar = %{partidas() => [1]}

      assert {:error, mensaje} =
               CatalogoGenerico.actualizar(pedido, :sistema, %{}, %{},
                 renglones_quitados: quitar,
                 escribir_renglones: fn _ ->
                   Renglones.eliminar_todos(maestro(), pedido.id, quitar)
                 end
               )

      assert mensaje =~ "no se pueden quitar renglones"
      assert productos_en_base(pedido.id) == ["Tornillos"]
    end

    test "cambiar partidas en un self-loop de un estado sin permite_actualizar se rechaza", %{
      maestro: maestro
    } do
      [baja] = MetaEstadosAdmin.listar_estados(maestro.id) |> Enum.filter(&(&1.nombre == "Baja"))

      {:ok, _} =
        MetaEstadosAdmin.crear_transicion(%{
          "meta_schema_header_id" => maestro.id,
          "accion" => "corregir",
          "etiqueta" => "Corregir",
          "estado_origen_id" => baja.id,
          "estado_destino_id" => baja.id,
          "campos_editables" => [producto()]
        })

      pedido = pedido!("P-3", ["Tornillos"]) |> en_baja!()

      assert {:error, mensaje} =
               MetaStateEngine.ejecutar_transicion(pedido, "corregir", %{},
                 renglones: %{partidas() => [%{"renglon_id" => 1, producto() => "Otro"}]}
               )

      assert mensaje =~ "En el estado Baja no se pueden cambiar renglones"
      assert productos_en_base(pedido.id) == ["Tornillos"]
    end

    test "en Activo quitar y cambiar siguen funcionando (R10)" do
      pedido = pedido!("P-4", ["Tornillos", "Tuercas"])

      assert {:ok, _} =
               MetaStateEngine.ejecutar_transicion(pedido, "guardar", %{},
                 renglones: %{partidas() => [%{"renglon_id" => 1, producto() => "Tornillos M8"}]}
               )

      assert {:ok, _} = Renglones.eliminar_todos(maestro(), pedido.id, %{partidas() => [2]})
      assert productos_en_base(pedido.id) == ["Tornillos M8"]
    end
  end

  describe "alta de un usuario solo con campos editables (R4-R7)" do
    setup %{maestro: maestro} do
      %{scope: usuario_scope_fixture(), maestro: maestro}
    end

    test "un campo de negocio que alta no tiene como editable se rechaza; :sistema sí pasa", %{
      scope: scope,
      maestro: maestro
    } do
      {:ok, _} =
        MetaEstadosAdmin.actualizar_transicion(transicion!(maestro, "alta"), %{
          "campos_editables" => []
        })

      antes = Repo.aggregate(PedidoPruebaMultinivel, :count)

      assert {:error, %Ecto.Changeset{} = cs} =
               CatalogoGenerico.crear(PedidoPruebaMultinivel, scope, %{folio() => "A-1"})

      assert {"no editable en el alta", _} = cs.errors[String.to_existing_atom(folio())]
      assert Repo.aggregate(PedidoPruebaMultinivel, :count) == antes

      assert {:ok, _} =
               CatalogoGenerico.crear(PedidoPruebaMultinivel, :sistema, %{folio() => "A-2"})
    end

    test "una partida con un campo editable=false en el contrato se rechaza", %{scope: scope} do
      [det] =
        MetaSchemaContext.listar_detalles(partidas())
        |> Enum.filter(&(&1.schema_context_field == producto()))

      {:ok, _} =
        MetaSchemaContext.actualizar_detalle(det, %{
          "schema_context_properties" => Map.put(det.schema_context_properties, "editable", false)
        })

      assert {:error, mensaje} = alta_con(scope, "A-3", ["Tornillos"])

      # Con las etiquetas que ve el usuario, no con los nombres técnicos.
      assert mensaje =~
               ~r/^Renglón 1 de Partidas prueba \d+: el campo Producto no es editable en el alta$/
    end

    test "criterio híbrido: si alta no lista campos del detalle, basta el contrato (R5, D3.1)", %{
      scope: scope
    } do
      # El fixture no lista partidas_prueba_multinivel_producto en `alta`.
      assert {:ok, pedido} = alta_con(scope, "A-4", ["Tornillos"])
      assert productos_en_base(pedido.id) == ["Tornillos"]
    end
  end

  defp alta_con(scope, folio, productos) do
    CatalogoGenerico.crear(PedidoPruebaMultinivel, scope, %{folio() => folio},
      renglones: %{partidas() => Enum.map(productos, &%{producto() => &1})}
    )
  end

  describe "referencia inexistente (R9, D5)" do
    # Tabla vieja con la llave nombrada al estilo de Ecto (<tabla>_<campo>_fkey).
    # El nombre que pone el generador hoy (<campo>_fkey) se verifica en dev
    # con pty_dsd_pedidos (03.tasks.md E3).
    test "el changeset regresa el campo en lugar de tronar" do
      assert {:error, cs} =
               %SubcategoriasPrueba{}
               |> SubcategoriasPrueba.changeset(%{
                 "subcategorias_prueba_nombre" => "X",
                 "subcategorias_prueba_categoria" => 999_999_999
               })
               |> Ecto.Changeset.change(%{insert_guid: "prueba"})
               |> Repo.insert()

      assert {"no existe un registro con este valor", _} =
               cs.errors[:subcategorias_prueba_categoria]
    end
  end
end
