defmodule MetadataApp.MetaImportacionRenglonesPreTest do
  # SPEC-SYS-0510202601 §2.5 (R8, R9): al importar renglones nuevos sobre un
  # registro que ya existe, la regla PRE del encabezado los ve antes de que
  # se creen. Escenario: MetadataApp.PedidoMultinivelFixtures y la regla de
  # prueba test/support/reglas_pedido_prueba_multinivel.ex.
  use MetadataApp.DataCase, async: true

  import MetadataApp.PedidoMultinivelFixtures

  alias MetadataApp.MetaImportacionDatos
  alias MetadataApp.MetaSchema.PlantillaImportacion

  # Plantilla en memoria: ejecutar/3 solo lee el header y la definición.
  # El folio identifica al pedido, así que una fila con un folio que ya
  # existe actualiza ese pedido y sus partidas van como nuevas.
  defp plantilla(maestro_header) do
    %PlantillaImportacion{
      meta_schema_header_id: maestro_header.id,
      definicion: %{
        "campos" => [%{"campo" => folio()}],
        "campo_identificador_encabezado" => folio(),
        "detalles" => [%{"catalogo" => partidas(), "activo" => true, "campos" => [%{"campo" => producto()}]}]
      }
    }
  end

  defp filas(folio, productos) do
    %{
      "encabezado" => [%{"Folio" => folio}],
      "detalles" => %{partidas() => Enum.map(productos, &%{"Folio" => folio, "Producto" => &1})}
    }
  end

  setup do
    %{maestro: registrar_metadata!()}
  end

  test "una partida nueva prohibida sobre un pedido existente se rechaza y no se crea (R8, R9)", %{maestro: maestro} do
    pedido = pedido!("I-1", ["Tornillos"])

    assert [%{resultado: :error}] = MetaImportacionDatos.ejecutar(plantilla(maestro), :sistema, filas("I-1", ["PROHIBIDO"]))

    assert_received {:pre_pedido, "guardar", propuestos}
    assert Enum.map(propuestos[partidas()], & &1["tipo"]) == ["existente", "nuevo"]
    assert productos_en_base(pedido.id) == ["Tornillos"]
  end

  test "una partida nueva válida se crea", %{maestro: maestro} do
    pedido = pedido!("I-2", ["Tornillos"])

    assert [%{resultado: resultado}] = MetaImportacionDatos.ejecutar(plantilla(maestro), :sistema, filas("I-2", ["Rondanas"]))
    refute resultado == :error
    assert productos_en_base(pedido.id) == ["Tornillos", "Rondanas"]
  end
end
