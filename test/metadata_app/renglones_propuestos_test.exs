defmodule MetadataApp.RenglonesPropuestosTest do
  # SPEC-SYS-0510202601 §2.1-§2.2 (R7, R10, R12): Renglones.propuestos/3 y
  # Renglones.vigentes/2. Tablas reales de prueba (pedido/partidas/lotes
  # _prueba_multinivel); su metadata se registra dentro de cada prueba,
  # porque la base de test no la trae. Lotes se registra como segundo
  # detalle directo del pedido solo para probar varios detalles.
  use MetadataApp.DataCase, async: true

  alias MetadataApp.{Renglones, Repo}
  alias MetadataApp.BusinessProcessBuilder.MetaSchemaContext
  alias MetadataApp.MetaBusinessProcess.Catalogos.{PedidoPruebaMultinivel, PartidasPruebaMultinivel, LotesPruebaMultinivel}

  @maestro "pedido_prueba_multinivel"
  @partidas "partidas_prueba_multinivel"
  @lotes "lotes_prueba_multinivel"

  defp guid, do: Ecto.UUID.generate() |> String.replace("-", "")

  defp registrar_header(nombre, encabezado_id) do
    s = System.unique_integer([:positive])

    {:ok, {header, _}} =
      MetaSchemaContext.crear_header_con_detalles(%{
        "schema_context_name" => nombre,
        "schema_context_label" => "#{nombre} #{s}",
        "schema_context_nav" => "/prueba-propuestos#{s}/#{nombre}",
        "schema_visible" => false,
        "schema_context_type" => 1,
        "schema_encabezado_id" => encabezado_id,
        "detalles" => []
      })

    header
  end

  defp pedido! do
    %PedidoPruebaMultinivel{}
    |> PedidoPruebaMultinivel.changeset(%{pedido_prueba_multinivel_folio: "P-#{System.unique_integer([:positive])}"})
    |> Ecto.Changeset.put_change(:insert_guid, guid())
    |> Repo.insert!()
  end

  defp partida!(encabezado_id, renglon_id, producto) do
    %PartidasPruebaMultinivel{}
    |> PartidasPruebaMultinivel.changeset(%{partidas_prueba_multinivel_producto: producto})
    |> Ecto.Changeset.change(%{insert_guid: guid(), encabezado_id: encabezado_id, renglon_id: renglon_id})
    |> Repo.insert!()
  end

  defp tipos_y_valores(propuestos, catalogo, campo) do
    Enum.map(propuestos[catalogo], &{&1["tipo"], Map.get(&1["registro"], campo)})
  end

  describe "sin catálogos detalle" do
    test "regresa nil (R10)" do
      registrar_header(@maestro, nil)
      assert Renglones.propuestos(@maestro, nil, %{}) == nil
    end
  end

  describe "con un catálogo detalle" do
    setup do
      maestro = registrar_header(@maestro, nil)
      registrar_header(@partidas, maestro.id)
      pedido = pedido!()
      %{pedido: pedido}
    end

    test "alta: solo los nuevos, sin leer existentes" do
      propuestos = Renglones.propuestos(@maestro, nil, %{nuevos: %{@partidas => [%{"partidas_prueba_multinivel_producto" => "Tornillos"}]}})

      assert tipos_y_valores(propuestos, @partidas, :partidas_prueba_multinivel_producto) == [{"nuevo", "Tornillos"}]
      assert [%{"registro" => %PartidasPruebaMultinivel{id: nil, renglon_id: nil, encabezado_id: nil}}] = propuestos[@partidas]
    end

    test "sin cambios: todos los existentes, en orden de renglón", %{pedido: pedido} do
      partida!(pedido.id, 2, "Tuercas")
      partida!(pedido.id, 1, "Tornillos")

      propuestos = Renglones.propuestos(@maestro, pedido.id)

      assert tipos_y_valores(propuestos, @partidas, :partidas_prueba_multinivel_producto) ==
               [{"existente", "Tornillos"}, {"existente", "Tuercas"}]
    end

    test "un renglón dado de baja no aparece", %{pedido: pedido} do
      partida!(pedido.id, 1, "Vivo")
      partida!(pedido.id, 2, "Borrado") |> Ecto.Changeset.change(%{delete_guid: guid()}) |> Repo.update!()

      propuestos = Renglones.propuestos(@maestro, pedido.id)
      assert tipos_y_valores(propuestos, @partidas, :partidas_prueba_multinivel_producto) == [{"existente", "Vivo"}]
    end

    test "editado reemplaza a su existente con los valores propuestos", %{pedido: pedido} do
      partida!(pedido.id, 1, "Tornillos")
      tuercas = partida!(pedido.id, 2, "Tuercas")
      editado = Ecto.Changeset.change(tuercas, %{partidas_prueba_multinivel_producto: "Tuercas M8"})

      propuestos = Renglones.propuestos(@maestro, pedido.id, %{editados: [editado]})

      assert tipos_y_valores(propuestos, @partidas, :partidas_prueba_multinivel_producto) ==
               [{"existente", "Tornillos"}, {"editado", "Tuercas M8"}]
    end

    test "quitado queda marcado, y nuevo va al final", %{pedido: pedido} do
      partida!(pedido.id, 1, "Tornillos")
      partida!(pedido.id, 2, "Tuercas")

      propuestos =
        Renglones.propuestos(@maestro, pedido.id, %{
          quitados: %{@partidas => [1]},
          nuevos: %{@partidas => [%{"partidas_prueba_multinivel_producto" => "Rondanas"}]}
        })

      assert tipos_y_valores(propuestos, @partidas, :partidas_prueba_multinivel_producto) ==
               [{"quitado", "Tornillos"}, {"existente", "Tuercas"}, {"nuevo", "Rondanas"}]

      assert [%{encabezado_id: id}] = propuestos[@partidas] |> Enum.filter(&(&1["tipo"] == "nuevo")) |> Enum.map(& &1["registro"])
      assert id == pedido.id
    end

    test "vigentes/2 regresa cómo quedará, sin los quitados", %{pedido: pedido} do
      partida!(pedido.id, 1, "Tornillos")
      partida!(pedido.id, 2, "Tuercas")

      contexto = %{"renglones_propuestos" => Renglones.propuestos(@maestro, pedido.id, %{quitados: %{@partidas => [2]}})}

      assert Enum.map(Renglones.vigentes(contexto, @partidas), & &1.partidas_prueba_multinivel_producto) == ["Tornillos"]
      assert Renglones.vigentes(contexto, "otro_catalogo") == []
      assert Renglones.vigentes(%{}, @partidas) == []
    end
  end

  describe "con varios catálogos detalle" do
    test "una entrada por cada detalle, aunque la operación no lo toque" do
      maestro = registrar_header(@maestro, nil)
      registrar_header(@partidas, maestro.id)
      registrar_header(@lotes, maestro.id)
      pedido = pedido!()
      partida!(pedido.id, 1, "Tornillos")

      propuestos = Renglones.propuestos(@maestro, pedido.id, %{nuevos: %{@lotes => [%{"lotes_prueba_multinivel_numero_lote" => "L-1"}]}})

      assert Map.keys(propuestos) |> Enum.sort() == Enum.sort([@partidas, @lotes])
      assert tipos_y_valores(propuestos, @partidas, :partidas_prueba_multinivel_producto) == [{"existente", "Tornillos"}]
      assert [%{"tipo" => "nuevo", "registro" => %LotesPruebaMultinivel{lotes_prueba_multinivel_numero_lote: "L-1"}}] = propuestos[@lotes]
    end
  end
end
