defmodule MetadataApp.PedidoMultinivelFixtures do
  @moduledoc """
  Maestro-detalle de prueba para SPEC-SYS-0510202601: registra la metadata
  de `pedido_prueba_multinivel` (estados Activo/Baja, transiciones alta,
  guardar y baja) y de su detalle `partidas_prueba_multinivel`, con los
  tres permisos de detalle en Activo. Las tablas y los schemas ya existen
  en el repo; la base de test no trae su metadata. La regla PRE del
  maestro está en test/support/reglas_pedido_prueba_multinivel.ex.
  """

  import Ecto.Query

  alias MetadataApp.{MetaEstadosAdmin, Repo}
  alias MetadataApp.BusinessProcessBuilder.{CatalogoGenerico, MetaSchemaContext}
  alias MetadataApp.MetaSchema.{Estado, Transicion}
  alias MetadataApp.MetaBusinessProcess.Catalogos.{PedidoPruebaMultinivel, PartidasPruebaMultinivel}

  @maestro "pedido_prueba_multinivel"
  @partidas "partidas_prueba_multinivel"
  @folio "pedido_prueba_multinivel_folio"
  @producto "partidas_prueba_multinivel_producto"

  def maestro, do: @maestro
  def partidas, do: @partidas
  def folio, do: @folio
  def producto, do: @producto

  @doc "Registra la metadata y regresa el header del maestro."
  def registrar_metadata! do
    s = System.unique_integer([:positive])

    {:ok, %{header: maestro}} =
      MetaEstadosAdmin.crear_proceso_completo(%{
        "header" => %{
          "schema_context_name" => @maestro,
          "schema_context_label" => "Pedido prueba #{s}",
          "schema_context_nav" => "/prueba-pedido#{s}/pedido",
          "schema_visible" => false,
          "schema_context_type" => 1,
          "schema_es_transaccional" => false,
          "requiere_folio" => false,
          "schema_encabezado_id" => nil,
          "detalles" => [campo(@folio, "Folio", 20)]
        },
        "estados" => [
          %{"nombre" => "Activo", "orden" => "1", "es_inicial" => true, "color" => "#40edb3"},
          %{"nombre" => "Baja", "orden" => "2", "es_inicial" => false, "color" => "#ed4051"}
        ],
        "transiciones" => [
          %{"accion" => "alta", "etiqueta" => "Nuevo", "estado_origen" => nil, "estado_destino" => "Activo", "campos_editables" => [@folio]},
          %{"accion" => "guardar", "etiqueta" => "Guardar", "estado_origen" => "Activo", "estado_destino" => "Activo", "campos_editables" => [@folio]},
          %{"accion" => "baja", "etiqueta" => "Baja", "estado_origen" => "Activo", "estado_destino" => "Baja", "campos_editables" => []}
        ]
      })

    {:ok, {detalle, _}} =
      MetaSchemaContext.crear_header_con_detalles(%{
        "schema_context_name" => @partidas,
        "schema_context_label" => "Partidas prueba #{s}",
        "schema_context_nav" => "/prueba-pedido#{s}/partidas",
        "schema_visible" => false,
        "schema_context_type" => 1,
        "schema_encabezado_id" => maestro.id,
        "detalles" => [campo(@producto, "Producto", 100)]
      })

    # El campo del detalle entra a "guardar" ya con el detalle registrado,
    # mismo orden que en el Motor.
    guardar = Repo.one!(from t in Transicion, where: t.meta_schema_header_id == ^maestro.id and t.accion == "guardar")
    {:ok, _} = MetaEstadosAdmin.actualizar_transicion(guardar, %{"campos_editables" => [@folio, @producto]})

    activo = Repo.one!(from e in Estado, where: e.meta_schema_header_id == ^maestro.id and e.nombre == "Activo")

    for permiso <- [:permite_insertar, :permite_actualizar, :permite_borrar],
        do: {:ok, _} = MetaEstadosAdmin.toggle_permiso_detalle(activo.id, detalle.id, permiso)

    maestro
  end

  @doc "Alta real (motor de estados) de un pedido con sus partidas."
  def alta(folio, productos) do
    CatalogoGenerico.crear(PedidoPruebaMultinivel, :sistema, %{@folio => folio},
      renglones: %{@partidas => Enum.map(productos, &%{@producto => &1})}
    )
  end

  def pedido!(folio, productos) do
    {:ok, pedido} = alta(folio, productos)
    pedido
  end

  @doc "Productos vivos de un pedido, en orden de renglón."
  def productos_en_base(pedido_id) do
    Repo.all(
      from p in PartidasPruebaMultinivel,
        where: p.encabezado_id == ^pedido_id and is_nil(p.delete_guid),
        order_by: p.renglon_id,
        select: p.partidas_prueba_multinivel_producto
    )
  end

  defp campo(nombre, etiqueta, longitud) do
    %{
      "schema_context_field" => nombre,
      "schema_context_properties" => %{
        "etiqueta" => etiqueta,
        "tipo" => "string",
        "orden" => 1,
        "visible" => true,
        "editable" => true,
        "opcional" => false,
        "longitud" => longitud
      }
    }
  end
end
