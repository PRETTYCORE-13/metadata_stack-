defmodule MetadataApp.RenglonesPropuestosConsultasTest do
  # SPEC-SYS-0510202601 R12: armar los renglones propuestos no hace una
  # consulta por renglón. Cuenta las consultas reales con la telemetría de
  # Ecto, solo las de este proceso (las pruebas corren en paralelo).
  # async: false -- registra la metadata de pedido_prueba_multinivel, y
  # schema_context_name es único: en paralelo, una prueba espera a que
  # termine la transacción de otra y se agotan los tiempos del sandbox.
  use MetadataApp.DataCase, async: false

  import MetadataApp.PedidoMultinivelFixtures

  alias MetadataApp.Renglones
  alias MetadataApp.BusinessProcessBuilder.MetaSchemaContext

  defp contar_consultas(fun) do
    prueba = self()
    ref = make_ref()
    handler = "conteo-consultas-#{inspect(ref)}"

    :telemetry.attach(handler, [:metadata_app, :repo, :query], fn _evento, _medidas, _meta, _config ->
      if self() == prueba, do: send(prueba, {:consulta, ref})
    end, nil)

    try do
      fun.()
      contar(ref, 0)
    after
      :telemetry.detach(handler)
    end
  end

  defp contar(ref, n) do
    receive do
      {:consulta, ^ref} -> contar(ref, n + 1)
    after
      0 -> n
    end
  end

  test "con 50 renglones: una consulta de detalles y una de existentes, no 50" do
    maestro = registrar_metadata!()
    pedido = pedido!("Q-1", Enum.map(1..50, &"Producto #{&1}"))

    consultas = contar_consultas(fn -> send(self(), {:propuestos, Renglones.propuestos(maestro.id, pedido.id, %{})}) end)

    assert_received {:propuestos, propuestos}
    assert length(propuestos[partidas()]) == 50
    assert consultas == 2
  end

  test "un catálogo sin detalles paga una sola consulta" do
    {:ok, {header, _}} =
      MetaSchemaContext.crear_header_con_detalles(%{
        "schema_context_name" => "sin_detalles_#{System.unique_integer([:positive])}",
        "schema_context_label" => "Sin detalles",
        "schema_context_nav" => "/prueba-consultas#{System.unique_integer([:positive])}/x",
        "schema_visible" => false,
        "schema_context_type" => 1,
        "detalles" => []
      })

    assert contar_consultas(fn -> assert Renglones.propuestos(header.id, 1, %{}) == nil end) == 1
  end
end
