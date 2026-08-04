defmodule MetadataApp.MetaConsultas do
  @moduledoc """
  Consulta Ecto (BC tipo 3): un reporte de solo lectura compuesto de N
  tablas unidas por relaciones ya existentes (campos tipo "referencia",
  los mismos que usa la función "Relaciones"). Sin tabla física propia,
  sin motor de estados, sin TRN — a diferencia de un catálogo normal,
  `MetaSchemaContext.modulo_por_nombre/1` nunca resuelve nada para el
  `schema_context_name` de una Consulta: los datos siempre se leen de
  `catalogo_base` y de los catálogos agregados en `joins`, nunca de una
  tabla propia.

  Cada tabla de la consulta recibe un binding nombrado dinámico (`:t0`
  para `catalogo_base`, `:t1`, `:t2`... para cada join en el orden en que
  se agregaron) — `construir_query_base/1` arma el join completo y
  devuelve también el mapa `catalogo => alias` para que el resto de las
  funciones (filtros, búsqueda, select, totales) sepan a qué tabla
  pertenece cada campo. Como puede haber campos con el mismo nombre en
  dos tablas distintas, el valor de cada columna en `filas`/`totales` se
  expone bajo una clave compuesta `"<catalogo>__<campo>"` (ver
  `clave_campo/1`) — nunca el nombre de campo crudo.
  """

  import Ecto.Query

  alias MetadataApp.Repo
  alias MetadataApp.MetaSchema.Consulta
  alias MetadataApp.BusinessProcessBuilder.MetaSchemaContext
  alias MetadataApp.BusinessProcessBuilder.CatalogoGenerico

  def obtener_por_header_id(header_id) do
    Repo.get_by(Consulta, meta_schema_header_id: header_id)
  end

  def obtener_por_catalogo(schema_context_name) do
    case MetaSchemaContext.obtener_header_por_nombre(schema_context_name) do
      nil -> nil
      header -> obtener_por_header_id(header.id)
    end
  end

  # Arma la consulta con TODOS los campos de catalogo_base ya
  # seleccionados y visibles — arranca completa, el admin la recorta
  # después desde el editor (mismo criterio que un catálogo normal: nace
  # con "visible: true" en todos sus campos).
  def crear(%{id: header_id}, catalogo_base) do
    %Consulta{}
    |> Consulta.changeset(%{
      "meta_schema_header_id" => header_id,
      "catalogo_base" => catalogo_base,
      "campos" => campos_del_catalogo(catalogo_base, 0)
    })
    |> Ecto.Changeset.change(%{insert_guid: generar_guid()})
    |> Repo.insert()
  end

  # Etiqueta tomada de meta_schema_detail si el campo existe ahí; si no
  # (columna sin contrato propio), el nombre lógico tal cual, sin
  # inventar una etiqueta bonita. `offset` corre el "orden" para que los
  # campos de una tabla agregada después queden siempre DESPUÉS de los ya
  # existentes (no se reusa el "orden" nativo del catálogo origen, que es
  # relativo solo a sus propios campos y colisionaría con el de otra
  # tabla ya presente).
  defp campos_del_catalogo(catalogo, offset) do
    catalogo
    |> MetaSchemaContext.listar_detalles()
    |> Enum.with_index()
    |> Enum.map(fn {detalle, indice} ->
      props = detalle.schema_context_properties || %{}

      %{
        "catalogo" => catalogo,
        "campo" => detalle.schema_context_field,
        "etiqueta" => Map.get(props, "etiqueta") || detalle.schema_context_field,
        "tipo" => Map.get(props, "tipo", "string"),
        "orden" => offset + indice,
        "visible" => true,
        "totalizar" => false
      }
    end)
  end

  def actualizar_campos(%Consulta{} = consulta, campos) do
    consulta
    |> Consulta.changeset(%{"campos" => campos})
    |> Ecto.Changeset.change(%{update_guid: generar_guid()})
    |> Repo.update()
  end

  @doc """
  Catálogos ya presentes en la consulta, en el orden en que se agregaron
  (`catalogo_base` primero) — el orden importa porque define los
  bindings `:t0`, `:t1`... de `construir_query_base/1`.
  """
  def catalogos_presentes(%Consulta{catalogo_base: base, joins: joins}) do
    [base | Enum.map(joins, & &1["catalogo"])]
  end

  @doc """
  Agrega una tabla relacionada a la consulta. Intenta autodetectar la
  unión buscando un campo tipo "referencia" que ya conecte esa tabla con
  alguna de las que ya están en la consulta (en cualquiera de las dos
  direcciones — ver `detectar_union/2`). Si no encuentra ninguna,
  devuelve `{:error, :sin_union}` y el admin tiene que definirla a mano
  con `agregar_tabla_manual/5`.

  Los campos de la tabla nueva se agregan todos, visibles, al final de
  la lista (mismo criterio que `crear/2` para `catalogo_base`).
  """
  def agregar_tabla(%Consulta{} = consulta, catalogo_nuevo) do
    case detectar_union(catalogos_presentes(consulta), catalogo_nuevo) do
      {:ok, union} -> guardar_tabla_nueva(consulta, catalogo_nuevo, union)
      :sin_union -> {:error, :sin_union}
    end
  end

  @doc """
  Igual que `agregar_tabla/2` pero con la unión definida a mano — para
  cuando `detectar_union/2` no encuentra nada (dos tablas sin ninguna
  "Relación" configurada entre sí) o el admin quiere unir por un campo
  distinto al autodetectado.
  """
  def agregar_tabla_manual(%Consulta{} = consulta, catalogo_nuevo, campo_en_nuevo, catalogo_destino, campo_en_destino) do
    union = %{
      "catalogo_destino" => catalogo_destino,
      "campo_en_destino" => campo_en_destino,
      "campo_en_nuevo" => campo_en_nuevo
    }

    guardar_tabla_nueva(consulta, catalogo_nuevo, union)
  end

  defp guardar_tabla_nueva(consulta, catalogo_nuevo, union) do
    join = Map.merge(union, %{"catalogo" => catalogo_nuevo, "tipo" => "left"})
    campos_nuevos = campos_del_catalogo(catalogo_nuevo, length(consulta.campos))

    consulta
    |> Consulta.changeset(%{"joins" => consulta.joins ++ [join], "campos" => consulta.campos ++ campos_nuevos})
    |> Ecto.Changeset.change(%{update_guid: generar_guid()})
    |> Repo.update()
  end

  # Un campo "referencia" siempre apunta al "id" del catálogo destino
  # (mismo contrato que usa CatalogoGenerico.mapa_acompanamiento/2 para
  # resolver "Relaciones") — por eso acá nunca hace falta preguntar cuál
  # es el campo remoto, solo de qué lado está la referencia:
  #
  #   Dirección A: la tabla que se agrega TIENE el campo referencia hacia
  #   alguna tabla ya presente (caso típico: agregás el lado "muchos"
  #   cuando el "uno" ya estaba).
  #
  #   Dirección B: alguna tabla ya presente tiene un campo referencia
  #   HACIA la tabla que se agrega (agregás el lado "uno" cuando el
  #   "muchos" ya estaba).
  @doc """
  Igual que la detección que hace `agregar_tabla/2` internamente, pero
  expuesta como función pura (sin tocar la base) — la usa BcListLive para
  mostrar en vivo, mientras se arma la consulta en el modal de creación,
  qué unión se va a usar ANTES de confirmar nada.
  """
  def detectar_union(catalogos_actuales, catalogo_nuevo) do
    via_nuevo =
      catalogo_nuevo
      |> MetaSchemaContext.listar_detalles()
      |> Enum.find_value(fn detalle ->
        props = detalle.schema_context_properties || %{}

        if props["tipo"] == "referencia" and props["catalogo"] in catalogos_actuales do
          %{"catalogo_destino" => props["catalogo"], "campo_en_destino" => "id", "campo_en_nuevo" => detalle.schema_context_field}
        end
      end)

    case via_nuevo || detectar_union_desde_existentes(catalogos_actuales, catalogo_nuevo) do
      nil -> :sin_union
      union -> {:ok, union}
    end
  end

  defp detectar_union_desde_existentes(catalogos_actuales, catalogo_nuevo) do
    Enum.find_value(catalogos_actuales, fn tabla ->
      tabla
      |> MetaSchemaContext.listar_detalles()
      |> Enum.find_value(fn detalle ->
        props = detalle.schema_context_properties || %{}

        if props["tipo"] == "referencia" and props["catalogo"] == catalogo_nuevo do
          %{"catalogo_destino" => tabla, "campo_en_destino" => detalle.schema_context_field, "campo_en_nuevo" => "id"}
        end
      end)
    end)
  end

  @doc """
  Quita la última tabla agregada (y sus campos) de la consulta — solo la
  última, para no dejar un join "huérfano" (uno que hubiera unido por
  ESTA tabla, si es que existiera, quedaría sin destino). La UI solo
  ofrece quitar de atrás para adelante por este motivo.
  """
  def quitar_ultima_tabla(%Consulta{joins: []}), do: {:error, :no_hay_tablas_para_quitar}

  def quitar_ultima_tabla(%Consulta{joins: joins, campos: campos} = consulta) do
    %{"catalogo" => catalogo} = List.last(joins)

    consulta
    |> Consulta.changeset(%{
      "joins" => List.delete_at(joins, -1),
      "campos" => Enum.reject(campos, &(&1["catalogo"] == catalogo))
    })
    |> Ecto.Changeset.change(%{update_guid: generar_guid()})
    |> Repo.update()
  end

  @doc """
  Clave bajo la que aparece un campo en `filas`/`totales` — namespaced
  con el catálogo dueño para que dos tablas con un campo del mismo
  nombre (ej. ambas con "nombre") nunca choquen en el mapa resultado.
  Con `String.to_atom/1` (no `to_existing_atom`) porque es un átomo
  compuesto que nunca existió antes — seguro acá porque "catalogo"/
  "campo" siempre vienen de catálogos ya dados de alta por un admin
  (universo acotado), nunca de texto libre de un usuario final.
  """
  def clave_campo(%{"catalogo" => catalogo, "campo" => campo}), do: String.to_atom("#{catalogo}__#{campo}")

  @doc """
  Nombres de campo utilizables como llave de unión para un catálogo: sus
  campos configurados en `meta_schema_detail` más `"id"` (que siempre
  existe pero nunca es un detail configurable, así que no aparece solo
  con `MetaSchemaContext.listar_detalles/1`). Usado por el editor manual
  de uniones cuando `detectar_union/2` no encuentra nada.
  """
  def campos_disponibles_para_union(catalogo) do
    nombres = catalogo |> MetaSchemaContext.listar_detalles() |> Enum.map(& &1.schema_context_field)
    Enum.uniq(["id" | nombres])
  end

  @doc """
  Arma la query con todos los joins de la consulta ya aplicados (sin
  select ni filtros todavía) y el mapa `catalogo => alias` de bindings
  nombrados (`:t0`, `:t1`...) para que el resto de las funciones puedan
  referirse a la tabla correcta de cada campo.
  """
  def construir_query_base(%Consulta{} = consulta) do
    tablas = [{consulta.catalogo_base, nil} | Enum.map(consulta.joins, &{&1["catalogo"], &1})]

    Enum.reduce(tablas, {nil, %{}}, fn {catalogo, join_spec}, {query_acc, alias_acc} ->
      indice = map_size(alias_acc)
      alias_actual = String.to_atom("t#{indice}")
      modulo = MetaSchemaContext.modulo_por_nombre(catalogo)

      nueva_query =
        if is_nil(query_acc) do
          from(r in modulo, as: ^alias_actual, where: is_nil(r.delete_guid))
        else
          alias_destino = Map.fetch!(alias_acc, join_spec["catalogo_destino"])
          campo_nuevo = String.to_existing_atom(join_spec["campo_en_nuevo"])
          campo_destino = String.to_existing_atom(join_spec["campo_en_destino"])

          join(query_acc, :left, [], j in ^modulo,
            as: ^alias_actual,
            on:
              field(as(^alias_actual), ^campo_nuevo) == field(as(^alias_destino), ^campo_destino) and
                is_nil(field(as(^alias_actual), :delete_guid))
          )
        end

      {nueva_query, Map.put(alias_acc, catalogo, alias_actual)}
    end)
  end

  @doc """
  Total de filas para los mismos filtros/búsqueda, sin paginar — para que
  CatalogoLive calcule `total_paginas` ANTES de pedir la página con el
  offset correcto, igual que ya hace para un catálogo normal.
  """
  def contar(%Consulta{} = consulta, filtros \\ %{}, busqueda \\ nil) do
    {base, alias_por_catalogo} = construir_query_base(consulta)

    base
    |> aplicar_filtros(filtros, consulta.campos, alias_por_catalogo)
    |> aplicar_busqueda(busqueda, consulta.campos, alias_por_catalogo)
    |> Repo.aggregate(:count)
  end

  @doc """
  Ejecuta la consulta y devuelve `%{filas:, total_filas:, totales:}`.
  `filtros`/`opciones`/`busqueda` — mismo shape exacto que
  `CatalogoGenerico.listar/4` + `contar/3`, para reusar el mismo popover
  de filtros de CatalogoLive sin ninguna adaptación (los nombres de
  campo siguen siendo los crudos, sin catálogo — ver nota en
  `aplicar_filtros/3` sobre el único caso raro que no cubre).

  `totales` — suma de cada campo marcado `"totalizar": true`, sobre TODAS
  las filas que matchean filtros/búsqueda (no solo la página actual).
  Las claves de `filas`/`totales` son las de `clave_campo/1`, no el
  nombre de campo crudo.
  """
  def ejecutar(%Consulta{} = consulta, filtros \\ %{}, opciones \\ [], busqueda \\ nil) do
    {base, alias_por_catalogo} = construir_query_base(consulta)
    visibles = campos_visibles_ordenados(consulta)

    query =
      base
      |> aplicar_filtros(filtros, consulta.campos, alias_por_catalogo)
      |> aplicar_busqueda(busqueda, consulta.campos, alias_por_catalogo)

    total_filas = Repo.aggregate(query, :count)
    select_filas = select_dinamico(visibles, alias_por_catalogo)

    filas =
      query
      |> select(^select_filas)
      |> CatalogoGenerico.aplicar_paginacion(opciones)
      |> Repo.all()

    %{filas: filas, total_filas: total_filas, totales: totales(query, consulta, alias_por_catalogo)}
  end

  defp campos_visibles_ordenados(%Consulta{campos: campos}) do
    campos
    |> Enum.filter(&(Map.get(&1, "visible") == true))
    |> Enum.sort_by(&Map.get(&1, "orden", 0))
  end

  defp select_dinamico(campos, alias_por_catalogo) do
    Map.new(campos, fn campo ->
      alias_tabla = Map.fetch!(alias_por_catalogo, campo["catalogo"])
      campo_atom = String.to_existing_atom(campo["campo"])
      {clave_campo(campo), dynamic([{^alias_tabla, t}], field(t, ^campo_atom))}
    end)
  end

  # `filtros`/`busqueda` siguen llegando con el nombre de campo CRUDO
  # (sin catálogo — mismo shape que ya arma CatalogoLive para un catálogo
  # normal), así que acá se resuelve a qué tabla pertenece buscando en
  # `campos`. Caso no cubierto, a propósito (no vale la pena la
  # complejidad extra para algo tan infrecuente): si DOS tablas de la
  # misma consulta tienen un campo con el mismo nombre crudo, el filtro
  # se aplica solo contra la PRIMERA coincidencia.
  defp aplicar_filtros(query, filtros, campos, alias_por_catalogo) do
    Enum.reduce(filtros, query, fn {campo_nombre, valor}, acc ->
      case resolver_campo(campos, alias_por_catalogo, campo_nombre) do
        nil -> acc
        {alias_tabla, campo_atom} -> aplicar_filtro(acc, alias_tabla, campo_atom, valor)
      end
    end)
  end

  defp resolver_campo(campos, alias_por_catalogo, campo_nombre) do
    case Enum.find(campos, &(&1["campo"] == to_string(campo_nombre))) do
      nil -> nil
      campo -> {Map.fetch!(alias_por_catalogo, campo["catalogo"]), String.to_existing_atom(campo["campo"])}
    end
  end

  # Mismos operadores que CatalogoGenerico.aplicar_filtro/3 (privada ahí,
  # así que se reimplementan acá) — la única diferencia es que cada
  # cláusula tiene que decir explícitamente a qué binding nombrado
  # pertenece el campo, ya que acá puede haber más de una tabla.
  defp aplicar_filtro(query, alias_tabla, campo, {:ilike, texto}) do
    patron = "%#{texto}%"
    where(query, [{^alias_tabla, t}], ilike(field(t, ^campo), ^patron))
  end

  defp aplicar_filtro(query, alias_tabla, campo, {:gte, valor}) do
    where(query, [{^alias_tabla, t}], field(t, ^campo) >= ^valor)
  end

  defp aplicar_filtro(query, alias_tabla, campo, {:lte, valor}) do
    where(query, [{^alias_tabla, t}], field(t, ^campo) <= ^valor)
  end

  defp aplicar_filtro(query, _alias_tabla, _campo, {:entre, {nil, nil}}), do: query
  defp aplicar_filtro(query, alias_tabla, campo, {:entre, {desde, nil}}), do: aplicar_filtro(query, alias_tabla, campo, {:gte, desde})
  defp aplicar_filtro(query, alias_tabla, campo, {:entre, {nil, hasta}}), do: aplicar_filtro(query, alias_tabla, campo, {:lte, hasta})

  defp aplicar_filtro(query, alias_tabla, campo, {:entre, {desde, hasta}}) do
    where(query, [{^alias_tabla, t}], field(t, ^campo) >= ^desde and field(t, ^campo) <= ^hasta)
  end

  defp aplicar_filtro(query, alias_tabla, campo, valor) do
    where(query, [{^alias_tabla, t}], field(t, ^campo) == ^valor)
  end

  defp aplicar_busqueda(query, nil, _campos, _alias_por_catalogo), do: query
  defp aplicar_busqueda(query, {texto, _campos_nombres}, _campos, _alias_por_catalogo) when texto in [nil, ""], do: query

  defp aplicar_busqueda(query, {texto, campos_nombres}, campos, alias_por_catalogo) do
    patron = "%#{texto}%"

    condicion =
      Enum.reduce(campos_nombres, dynamic(false), fn campo_nombre, acc ->
        case resolver_campo(campos, alias_por_catalogo, campo_nombre) do
          nil -> acc
          {alias_tabla, campo_atom} -> dynamic([{^alias_tabla, t}], ^acc or fragment("?::text ILIKE ?", field(t, ^campo_atom), ^patron))
        end
      end)

    where(query, ^condicion)
  end

  defp totales(query_filtrada, %Consulta{campos: campos}, alias_por_catalogo) do
    campos_a_sumar = Enum.filter(campos, &(Map.get(&1, "totalizar") == true))

    case campos_a_sumar do
      [] ->
        %{}

      _ ->
        select_totales = select_dinamico_suma(campos_a_sumar, alias_por_catalogo)

        query_filtrada
        # order_by choca con un SELECT agregado sin GROUP BY (no tiene
        # sentido ordenar una sola fila totalizada) — se descarta acá,
        # nunca afecta el order_by real de `filas`.
        |> exclude(:order_by)
        |> select(^select_totales)
        |> Repo.one()
        |> Kernel.||(%{})
    end
  end

  defp select_dinamico_suma(campos, alias_por_catalogo) do
    Map.new(campos, fn campo ->
      alias_tabla = Map.fetch!(alias_por_catalogo, campo["catalogo"])
      campo_atom = String.to_existing_atom(campo["campo"])
      {clave_campo(campo), dynamic([{^alias_tabla, t}], sum(field(t, ^campo_atom)))}
    end)
  end

  @doc """
  Igual que `CatalogoGenerico.agregar/5`, pero para una Consulta con JOIN
  — `campo_clave` es la clave namespaced (ver `clave_campo/1`, como
  string) porque acá puede haber más de una tabla y el campo crudo solo
  identifica la columna dentro de SU catálogo, no en toda la consulta.
  `funcion` es uno de :sum/:avg/:min/:max/:count. nil si `campo_clave` no
  existe en la consulta (defensivo — no debería pasar desde la UI).
  """
  def agregar(%Consulta{} = consulta, campo_clave, funcion, filtros \\ %{}, busqueda \\ nil) do
    case Enum.find(consulta.campos, &(to_string(clave_campo(&1)) == campo_clave)) do
      nil ->
        nil

      campo ->
        {base, alias_por_catalogo} = construir_query_base(consulta)
        alias_tabla = Map.fetch!(alias_por_catalogo, campo["catalogo"])
        campo_atom = String.to_existing_atom(campo["campo"])
        expr = dynamic([{^alias_tabla, t}], field(t, ^campo_atom))

        base
        |> aplicar_filtros(filtros, consulta.campos, alias_por_catalogo)
        |> aplicar_busqueda(busqueda, consulta.campos, alias_por_catalogo)
        |> exclude(:order_by)
        |> select(^aplicar_funcion_agregada(funcion, expr))
        |> Repo.one()
    end
  end

  defp aplicar_funcion_agregada(:sum, expr), do: dynamic(sum(^expr))
  defp aplicar_funcion_agregada(:avg, expr), do: dynamic(avg(^expr))
  defp aplicar_funcion_agregada(:min, expr), do: dynamic(min(^expr))
  defp aplicar_funcion_agregada(:max, expr), do: dynamic(max(^expr))
  defp aplicar_funcion_agregada(:count, expr), do: dynamic(count(^expr))

  defp generar_guid do
    Ecto.UUID.generate() |> String.replace("-", "")
  end
end
