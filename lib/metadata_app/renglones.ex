defmodule MetadataApp.Renglones do
  @moduledoc """
  Asigna `encabezado_id`/`renglon_id` a un registro de un catálogo detalle
  del motor Maestro-Detalle (ver
  `docs/catalogo-maestro-detalle-requerimientos.md`, R1/R14). `renglon_id`
  es un contador POR MAESTRO — arranca en 1 para cada encabezado, no es un
  autoincremental global de Postgres — así que se calcula con un lock
  sobre la fila del maestro (`FOR UPDATE`) para que dos altas concurrentes
  del mismo encabezado no calculen el mismo número. `id` sigue siendo la
  PK física de siempre (decisión 14.a) — esto solo agrega las dos
  columnas de sistema, no reemplaza nada del motor existente.

  Se llama siempre desde `CatalogoGenerico.crear/2` (vía `crear_simple/2`),
  nunca a mano. Si el catálogo no es detalle, `preparar/3` es un
  pass-through — no cambia nada del comportamiento de siempre.

  También asigna `estado_id` al nacer (Fase 2, ver R3 del requerimiento):
  `MetaStateEngine.estado_inicial/1` no sirve acá — busca `es_inicial`
  en el header del catálogo DETALLE, que nunca tiene estados propios (los
  estados/transiciones viven una sola vez, en el maestro). Un renglón nace
  con el estado ACTUAL del maestro (leído en el mismo lock que ya evita la
  carrera de renglon_id) — así ya puede participar de la próxima transición
  que el maestro ejecute, sin quedar en `estado_id: nil`.

  `crear_todos/3` (R6, alta atómica): crea los renglones iniciales de un
  maestro recién dado de alta, en el MISMO `Ecto.Multi` que su propio
  registro (llamado desde `MetaStateEngine.ejecutar_nucleo_alta/4` y
  `CatalogoGenerico.crear_simple/3`). Reusa `CatalogoGenerico.crear/2` por
  renglón — mismo lock/asignación de `renglon_id`/`estado_id` que
  `preparar/3` ya resuelve para cualquier alta de un catálogo detalle, sin
  duplicar esa lógica. Un `Repo.transaction/1` anidado (el de
  `crear_simple/3`) dentro de la transacción externa del `Multi` no abre
  una transacción real aparte — Ecto lo aplana, participa de la misma
  atomicidad: si un renglón falla, se aborta TODO (maestro incluido).
  """

  alias MetadataApp.Repo
  alias MetadataApp.BusinessProcessBuilder.MetaSchemaContext

  @doc """
  `changeset -> changeset`, con `encabezado_id`/`renglon_id` resueltos si
  `catalogo` es un catálogo detalle (o sin cambios si no lo es). Agrega un
  error al changeset (no levanta excepción) si el catálogo es detalle y
  `attrs` no trae un `encabezado_id` válido — mismo criterio que cualquier
  otra validación de negocio en este motor.
  """
  def preparar(changeset, catalogo, attrs) do
    header = MetaSchemaContext.obtener_header_por_nombre(catalogo)

    if header && header.schema_encabezado_id do
      maestro = MetaSchemaContext.obtener_header!(header.schema_encabezado_id)
      resolver(changeset, catalogo, maestro, attrs)
    else
      changeset
    end
  end

  defp resolver(changeset, catalogo, maestro, attrs) do
    case Map.get(attrs, "encabezado_id") || Map.get(attrs, :encabezado_id) do
      nil ->
        Ecto.Changeset.add_error(changeset, :encabezado_id, "es obligatorio para un catálogo detalle")

      encabezado_id ->
        case lockear_maestro(maestro.schema_context_name, encabezado_id) do
          {:ok, estado_maestro} ->
            renglon_id = siguiente_renglon(catalogo, encabezado_id)

            Ecto.Changeset.change(changeset, %{
              encabezado_id: encabezado_id,
              renglon_id: renglon_id,
              estado_id: estado_maestro
            })

          :error ->
            Ecto.Changeset.add_error(changeset, :encabezado_id, "el encabezado #{encabezado_id} no existe")
        end
    end
  end

  # FOR UPDATE sobre la fila del maestro: mientras esta transacción esté
  # abierta, cualquier otra alta de un renglón del MISMO maestro espera acá
  # — así dos altas concurrentes nunca calculan el mismo siguiente_renglon/2,
  # y de paso se lee su estado_id ACTUAL para el nuevo renglón (ver
  # moduledoc). No lockea nada si el maestro no existe o ya está borrado.
  defp lockear_maestro(tabla_maestro, id) do
    case Repo.query("SELECT estado_id FROM #{tabla_maestro} WHERE id = $1 AND delete_guid IS NULL FOR UPDATE", [id]) do
      {:ok, %{rows: [[estado_id]]}} -> {:ok, estado_id}
      _sin_filas_o_error -> :error
    end
  end

  defp siguiente_renglon(catalogo, encabezado_id) do
    %{rows: [[maximo]]} =
      Repo.query!("SELECT COALESCE(MAX(renglon_id), 0) FROM #{catalogo} WHERE encabezado_id = $1", [encabezado_id])

    maximo + 1
  end

  @doc """
  `renglones_spec`: `%{"catalogo_detalle" => [attrs_map, ...]}` — crea cada
  renglón para el maestro `catalogo_maestro` (schema_context_name) recién
  insertado con id `registro_id`. `%{}` es no-op (la enorme mayoría de
  altas, catálogos sin detalle). Estructural, mismo criterio que
  `MetaStateEngine`'s `resolver_renglones/3` (Fase 2/3): valida que cada
  catálogo nombrado sea de verdad detalle de ESTE maestro antes de crear
  nada — un error acá rechaza el alta completa.
  """
  def crear_todos(_catalogo_maestro, _registro_id, renglones_spec) when map_size(renglones_spec) == 0,
    do: {:ok, []}

  def crear_todos(catalogo_maestro, registro_id, renglones_spec) do
    header_maestro = MetaSchemaContext.obtener_header_por_nombre(catalogo_maestro)

    Enum.reduce_while(renglones_spec, {:ok, []}, fn {catalogo, items}, {:ok, acc} ->
      case crear_renglones_de_catalogo(header_maestro, registro_id, catalogo, items) do
        {:ok, creados} -> {:cont, {:ok, acc ++ creados}}
        {:error, _motivo} = error -> {:halt, error}
      end
    end)
  end

  defp crear_renglones_de_catalogo(header_maestro, registro_id, catalogo, items) do
    modulo = MetaSchemaContext.modulo_por_nombre(catalogo)
    header_detalle = MetaSchemaContext.obtener_header_por_nombre(catalogo)

    cond do
      is_nil(modulo) or is_nil(header_detalle) ->
        {:error, "catálogo detalle '#{catalogo}' no existe"}

      header_detalle.schema_encabezado_id != header_maestro.id ->
        {:error, "'#{catalogo}' no es un catálogo detalle de este maestro"}

      true ->
        crear_cada_renglon(modulo, registro_id, items)
    end
  end

  defp crear_cada_renglon(modulo, registro_id, items) do
    Enum.reduce_while(items, {:ok, []}, fn item_attrs, {:ok, acc} ->
      attrs = Map.put(item_attrs, "encabezado_id", registro_id)

      case MetadataApp.BusinessProcessBuilder.CatalogoGenerico.crear(modulo, attrs) do
        {:ok, renglon} -> {:cont, {:ok, [renglon | acc]}}
        {:error, _motivo} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, lista} -> {:ok, Enum.reverse(lista)}
      error -> error
    end
  end
end
