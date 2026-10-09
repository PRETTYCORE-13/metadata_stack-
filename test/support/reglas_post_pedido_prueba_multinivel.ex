defmodule MetadataApp.MetaBusinessProcess.Reglas.PedidoPruebaMultinivel.Post do
  @moduledoc false
  # POST de prueba del maestro pedido_prueba_multinivel, para
  # SPEC-SYS-0710202602 (la regla POST del encabezado corre con sus renglones
  # ya guardados, ver test/metadata_app/meta_state_engine/post_con_renglones_test.exs).
  #
  # Lee de la base las partidas vivas del pedido y le avisa a la prueba qué
  # vio. Solo actúa con marcadores en el folio, para no afectar a otras
  # pruebas que usan este catálogo:
  #   - "POST-FALLA...": regresa error (no debe quedar nada guardado);
  #   - "POST-ESCRIBE...": agrega "*" a cada partida y escribe en el folio
  #     cuántas partidas vio.
  @behaviour MetadataApp.MetaStateEngine.ReglaPost

  import Ecto.Query

  alias MetadataApp.MetaBusinessProcess.Catalogos.{
    PedidoPruebaMultinivel,
    PartidasPruebaMultinivel
  }

  @impl true
  def ejecutar(accion, registro, _contexto, repo) when accion in ["alta", "guardar"] do
    vivas =
      from(p in PartidasPruebaMultinivel,
        where: p.encabezado_id == ^registro.id and is_nil(p.delete_guid)
      )

    partidas =
      repo.all(
        from p in vivas,
          order_by: p.renglon_id,
          select: {p.id, p.renglon_id, p.partidas_prueba_multinivel_producto}
      )

    send(self(), {:post_pedido, accion, partidas})
    folio = registro.pedido_prueba_multinivel_folio || ""

    cond do
      String.starts_with?(folio, "POST-FALLA") ->
        {:error, "falla de prueba del POST"}

      String.starts_with?(folio, "POST-ESCRIBE") ->
        repo.update_all(
          from(p in vivas,
            update: [
              set: [
                partidas_prueba_multinivel_producto:
                  fragment("? || '*'", p.partidas_prueba_multinivel_producto)
              ]
            ]
          ),
          []
        )

        repo.update_all(from(r in PedidoPruebaMultinivel, where: r.id == ^registro.id),
          set: [pedido_prueba_multinivel_folio: "POST-ESCRIBE (#{length(partidas)})"]
        )

        {:ok, :escrito}

      true ->
        {:ok, :sin_cambios}
    end
  end

  def ejecutar(_accion, _registro, _contexto, _repo), do: {:ok, :sin_cambios}

  # SPEC-SYS-0810202603: cálculo preliminar según el producto capturado.
  # "CALC..." también regresa el producto (capturable), que la plataforma
  # debe ignorar; insert_guid hace de columna de solo lectura en las pruebas.
  @impl true
  def calcular_renglon("partidas_prueba_multinivel", encabezado, renglon) do
    producto = renglon["partidas_prueba_multinivel_producto"] || ""

    cond do
      String.starts_with?(producto, "AVISO") -> {:aviso, "sin precio de prueba"}
      String.starts_with?(producto, "BOOM") -> raise "falla de prueba del cálculo"
      String.starts_with?(producto, "CALC") ->
        {:ok, %{"insert_guid" => "#{producto}/#{encabezado["pedido_prueba_multinivel_folio"]}", "partidas_prueba_multinivel_producto" => "otro"}}

      true -> :sin_calculo
    end
  end

  def calcular_renglon(_detalle, _encabezado, _renglon), do: :sin_calculo
end
