defmodule MetadataApp.Purga.Unidad do
  @moduledoc """
  La unidad que se retira o purga (SPEC-ARQ-3009202601, R3, design §3): un
  catálogo maestro `pty_*` más todos sus detalles, a cualquier
  profundidad, y las migraciones que les pertenecen.

  Corre igual en el BPB local y dentro del pod de un sistema destino
  (`MetadataApp.Release.Purga`): la lectura de metadata es una query sin
  schema que solo pide `id`, `schema_context_name` y
  `schema_encabezado_id`, así que no truena en una base donde todavía no
  existe una columna agregada después a `meta_schema_header` (mismo
  motivo que `MetaSchemaContext.obtener_id_por_nombre/1`).
  """

  import Ecto.Query

  @nombre_valido ~r/^pty_[a-z0-9_]+$/

  @doc "¿`nombre` es un nombre de tabla que la purga puede tocar? Solo `pty_*`."
  def nombre_valido?(nombre) when is_binary(nombre), do: Regex.match?(@nombre_valido, nombre)
  def nombre_valido?(_), do: false

  @doc """
  Tablas del artefacto cuyo maestro es `maestro`, leídas de `repo`.
  Ver `tablas_de/2`.
  """
  def tablas(repo, maestro) do
    tablas_de(maestro, headers(repo))
  end

  @doc """
  Todas las unidades presentes en `repo`: `[%{maestro: nombre, tablas: [...]}]`,
  ordenadas por maestro. Ver `unidades_de/1`.
  """
  def unidades(repo), do: unidades_de(headers(repo))

  @doc """
  Filas mínimas de `meta_schema_header`: `%{id, nombre, encabezado_id, tipo}`.
  Incluye headers con borrado lógico: su tabla física puede seguir
  existiendo y la purga no debe dejarla atrás.
  """
  def headers(repo) do
    repo.all(
      from h in "meta_schema_header",
        select: %{
          id: h.id,
          nombre: h.schema_context_name,
          encabezado_id: h.schema_encabezado_id,
          tipo: h.schema_context_type
        }
    )
  end

  @doc """
  Tablas de la unidad de `maestro` dentro de `headers`, de la más
  profunda al maestro (el orden en que se pueden borrar sin violar la FK
  detalle → maestro).

  Catálogos (`schema_context_type` 1), consultas (3) y consultas SQL (4,
  R15). Una consulta no tiene detalles: su unidad es ella sola. Una
  carpeta (2) no se purga: es estructura del menú.

  `{:ok, tablas}` | `{:error, :no_existe}` | `{:error, {:es_detalle, maestro_raiz}}`
  | `{:error, :nombre_invalido}` | `{:error, {:no_purgable, tipo}}`.
  """
  def tablas_de(maestro, headers) do
    por_nombre = Map.new(headers, &{&1.nombre, &1})

    cond do
      not nombre_valido?(maestro) ->
        {:error, :nombre_invalido}

      not Map.has_key?(por_nombre, maestro) ->
        {:error, :no_existe}

      not purgable?(por_nombre[maestro]) ->
        {:error, {:no_purgable, tipo(por_nombre[maestro])}}

      por_nombre[maestro].encabezado_id != nil ->
        {:error, {:es_detalle, raiz(por_nombre[maestro], Map.new(headers, &{&1.id, &1}))}}

      true ->
        hijos = Enum.group_by(headers, & &1.encabezado_id)
        {:ok, descendientes_primero(por_nombre[maestro], hijos)}
    end
  end

  @doc """
  Agrupa `headers` en unidades `pty_*` purgables: un elemento por raíz,
  `%{maestro, tablas, tipo}`.
  """
  def unidades_de(headers) do
    hijos = Enum.group_by(headers, & &1.encabezado_id)

    headers
    |> Enum.filter(&(is_nil(&1.encabezado_id) and purgable?(&1) and nombre_valido?(&1.nombre)))
    |> Enum.sort_by(& &1.nombre)
    |> Enum.map(&%{maestro: &1.nombre, tablas: descendientes_primero(&1, hijos), tipo: tipo(&1)})
  end

  @doc "Nombre del tipo de artefacto según `schema_context_type`."
  def nombre_tipo(1), do: :catalogo
  def nombre_tipo(2), do: :carpeta
  def nombre_tipo(3), do: :consulta
  def nombre_tipo(4), do: :consulta_sql
  def nombre_tipo(_), do: :desconocido

  # Sin `tipo` en la fila (mapas armados a mano) se asume catálogo, el
  # default de la columna.
  defp tipo(header), do: Map.get(header, :tipo) || 1
  defp purgable?(header), do: tipo(header) in [1, 3, 4]

  # Recorrido en profundidad con postorden: cada detalle sale antes que su
  # maestro. `visitados` corta un ciclo si la metadata llegara corrupta
  # (Header.changeset ya lo impide al guardar).
  defp descendientes_primero(header, hijos, visitados \\ MapSet.new()) do
    if MapSet.member?(visitados, header.id) do
      []
    else
      visitados = MapSet.put(visitados, header.id)

      hijos
      |> Map.get(header.id, [])
      |> Enum.sort_by(& &1.nombre)
      |> Enum.flat_map(&descendientes_primero(&1, hijos, visitados))
      |> Enum.concat([header.nombre])
    end
  end

  defp raiz(header, por_id, visitados \\ MapSet.new()) do
    padre = header.encabezado_id && por_id[header.encabezado_id]

    if is_nil(padre) or MapSet.member?(visitados, header.id),
      do: header.nombre,
      else: raiz(padre, por_id, MapSet.put(visitados, header.id))
  end

  @doc """
  Los archivos de `nombres` (basenames de migraciones) que pertenecen a
  `tablas`. Un archivo pertenece a una tabla si termina en
  `_<tabla>.exs` o `_<tabla>_<14 dígitos>.exs` (así nombra el generador
  todas sus migraciones, y la regla del equipo para las manuales).

  Nunca un comodín `*<tabla>*`: `pty_marcas` no atrapa `pty_marcas_v2`.
  Si un archivo coincide con varias tablas de `universo` (todas las tablas
  conocidas; por ejemplo `pty_a` y `pty_b_pty_a`), se asigna a la más
  larga, la más específica.
  """
  def migraciones(tablas, nombres, universo \\ []) do
    candidatas = Enum.uniq(tablas ++ universo)
    propias = MapSet.new(tablas)

    Enum.filter(nombres, fn nombre ->
      case tabla_de_migracion(nombre, candidatas) do
        nil -> false
        tabla -> MapSet.member?(propias, tabla)
      end
    end)
  end

  @doc "La tabla de `candidatas` a la que pertenece la migración `nombre`, o `nil`."
  def tabla_de_migracion(nombre, candidatas) do
    candidatas
    |> Enum.filter(&Regex.match?(~r/_#{Regex.escape(&1)}(_\d{14})?\.exs$/, nombre))
    |> Enum.max_by(&String.length/1, fn -> nil end)
  end

  @doc "Versión de Ecto de una migración: el prefijo numérico de su nombre."
  def version(nombre) do
    nombre |> Path.basename() |> String.split("_", parts: 2) |> hd() |> String.to_integer()
  end
end
