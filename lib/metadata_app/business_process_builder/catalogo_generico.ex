defmodule MetadataApp.BusinessProcessBuilder.CatalogoGenerico do
  alias MetadataApp.Repo
  import Ecto.Query

  # filtros: %{"campo" => valor, ...} — combinados con AND, solo columnas
  # reales de la tabla (no campos calculados como estado_nombre). Usado por
  # MetaBcCliente.listar/2 para que una regla de negocio pueda filtrar otro
  # catálogo sin escribir la query a mano. `valor` acepta también una tupla
  # con operador — {:ilike, texto}, {:gte, valor}, {:lte, valor},
  # {:entre, {desde, hasta}} (cualquiera de los dos puede ir nil, ej.
  # {:entre, {100, nil}} es "desde 100 en adelante") — usado por
  # CatalogoLive para los filtros dinámicos por columna. Un valor plano
  # (no tupla) sigue siendo igualdad exacta, como siempre.
  #
  # opciones: [] por default — sin :limit/:offset trae TODO, el
  # comportamiento de siempre. MetaBcCliente.listar/2 sigue llamando sin
  # opciones a propósito: una regla de negocio necesita ver el conjunto
  # COMPLETO de relacionados (sin_relacionados, mutar_relacionados), no una
  # página — paginar ahí rompería esas reglas en silencio. El único caller
  # que pasa :limit/:offset es CatalogoController.index/2 (la API HTTP).
  #
  # busqueda: nil por default, o {texto, campos} — a diferencia de filtros
  # (AND por columna, para acotar), esto es OR entre TODAS las columnas
  # dadas (para buscar rápido sin saber en qué campo está). campos castea
  # cada columna a texto para poder buscar "999" y encontrar un precio,
  # aunque la columna sea numérica.
  #
  # order_by es incondicional, no depende de opciones: sin un orden
  # estable, Postgres no garantiza el mismo resultado entre llamadas — con
  # LIMIT/OFFSET eso significa filas repetidas o salteadas entre páginas,
  # en silencio. Mismo tipo de bug ya visto antes en este proyecto
  # (exports sin order_by producían diffs sin sentido).
  def listar(schema_mod, filtros \\ %{}, opciones \\ [], busqueda \\ nil) do
    from(r in schema_mod, where: is_nil(r.delete_guid), order_by: [asc: r.id])
    |> aplicar_filtros(filtros)
    |> aplicar_busqueda(busqueda)
    |> aplicar_paginacion(opciones)
    |> Repo.all()
  end

  # Total de filas para los mismos filtros/búsqueda, sin paginar — para
  # calcular total_paginas en la respuesta HTTP.
  def contar(schema_mod, filtros \\ %{}, busqueda \\ nil) do
    from(r in schema_mod, where: is_nil(r.delete_guid))
    |> aplicar_filtros(filtros)
    |> aplicar_busqueda(busqueda)
    |> Repo.aggregate(:count)
  end

  defp aplicar_filtros(query, filtros) do
    Enum.reduce(filtros, query, fn {campo, valor}, acc ->
      campo_atom = String.to_existing_atom(to_string(campo))
      aplicar_filtro(acc, campo_atom, valor)
    end)
  end

  defp aplicar_filtro(query, campo, {:ilike, texto}) do
    patron = "%#{texto}%"
    from(r in query, where: ilike(field(r, ^campo), ^patron))
  end

  defp aplicar_filtro(query, campo, {:gte, valor}) do
    from(r in query, where: field(r, ^campo) >= ^valor)
  end

  defp aplicar_filtro(query, campo, {:lte, valor}) do
    from(r in query, where: field(r, ^campo) <= ^valor)
  end

  defp aplicar_filtro(query, _campo, {:entre, {nil, nil}}), do: query
  defp aplicar_filtro(query, campo, {:entre, {desde, nil}}), do: aplicar_filtro(query, campo, {:gte, desde})
  defp aplicar_filtro(query, campo, {:entre, {nil, hasta}}), do: aplicar_filtro(query, campo, {:lte, hasta})

  defp aplicar_filtro(query, campo, {:entre, {desde, hasta}}) do
    from(r in query, where: field(r, ^campo) >= ^desde and field(r, ^campo) <= ^hasta)
  end

  defp aplicar_filtro(query, campo, valor) do
    from(r in query, where: field(r, ^campo) == ^valor)
  end

  defp aplicar_busqueda(query, nil), do: query
  defp aplicar_busqueda(query, {texto, _campos}) when texto in [nil, ""], do: query

  defp aplicar_busqueda(query, {texto, campos}) do
    patron = "%#{texto}%"

    condicion =
      Enum.reduce(campos, dynamic(false), fn campo, acc ->
        campo_atom = String.to_existing_atom(to_string(campo))
        dynamic([r], ^acc or fragment("?::text ILIKE ?", field(r, ^campo_atom), ^patron))
      end)

    from(r in query, where: ^condicion)
  end

  defp aplicar_paginacion(query, opciones) do
    query
    |> aplicar_limit(Keyword.get(opciones, :limit))
    |> aplicar_offset(Keyword.get(opciones, :offset))
  end

  defp aplicar_limit(query, nil), do: query
  defp aplicar_limit(query, limit), do: from(r in query, limit: ^limit)

  defp aplicar_offset(query, nil), do: query
  defp aplicar_offset(query, offset), do: from(r in query, offset: ^offset)

  def obtener!(schema_mod, id) do
    Repo.one!(from(r in schema_mod, where: r.id == ^id and is_nil(r.delete_guid)))
  end

  # Si el catálogo definió una transición "alta" (estado_origen_id nil, ver
  # MetaStateEngine.transicion_alta/1), el nacimiento del registro pasa por el
  # mismo ciclo de reglas pre/post que cualquier transición — permite
  # prevalidar (campos_requeridos, requiere_rol, ...) o disparar efectos
  # (estampar_valor, notificar, ...) al crear, no solo al transicionar
  # después. Si el catálogo nunca definió esa transición (ej. pty_clientes
  # hoy), sigue el insert directo de siempre — 100% retrocompatible.
  def crear(schema_mod, attrs) do
    catalogo = schema_mod.__schema__(:source)

    resultado =
      case MetadataApp.MetaStateEngine.transicion_alta(catalogo) do
        nil -> crear_simple(schema_mod, attrs)
        transicion -> MetadataApp.MetaStateEngine.dar_de_alta(schema_mod, attrs, transicion, attrs)
      end

    # PrettyCore TRN (Fase 1) — Regla #1: ninguna operación transaccional
    # nace sin TRN. Corre DESPUÉS del insert (no en el mismo changeset)
    # para no acoplar MetadataApp.MetaStateEngine —deliberadamente
    # agnóstico del catálogo— a este concepto de negocio. Sin ventana
    # observable desde afuera: crear/2 no devuelve el registro hasta que
    # esto termina. No hace nada si el catálogo no es transaccional.
    MetadataApp.TRN.asignar_si_transaccional(resultado)
  end

  defp crear_simple(schema_mod, attrs) do
    catalogo = schema_mod.__schema__(:source)
    estado_inicial = MetadataApp.MetaStateEngine.estado_inicial(catalogo)

    schema_mod
    |> struct()
    |> schema_mod.changeset(attrs)
    |> Ecto.Changeset.change(%{insert_guid: generar_guid()})
    |> asignar_estado_inicial(estado_inicial)
    |> Repo.insert()
  end

  # Si el catálogo adoptó el motor de estados, todo registro nuevo nace en
  # su estado inicial — si no, no hay nada que asignar (estado_id queda nil,
  # como siempre para catálogos sin motor de estados).
  defp asignar_estado_inicial(changeset, nil), do: changeset

  defp asignar_estado_inicial(changeset, estado_inicial),
    do: Ecto.Changeset.change(changeset, %{estado_id: estado_inicial.id})

  # Crea varios registros del mismo catálogo en una sola transacción.
  # Si alguno falla, se revierten todos (todo o nada).
  def crear_muchos(schema_mod, lista_attrs) when is_list(lista_attrs) do
    Repo.transaction(fn ->
      Enum.map(lista_attrs, fn attrs ->
        case crear(schema_mod, attrs) do
          {:ok, registro} -> registro
          {:error, changeset} -> Repo.rollback(changeset)
        end
      end)
    end)
  end

  # Si el catálogo definió una transición "guardar" (self-loop en el estado
  # actual, ver MetaStateEngine.transicion_guardar/2), la edición corre el
  # mismo ciclo de reglas pre/post que cualquier transición — las PRE ven
  # los valores YA PROPUESTOS (permite bloquear "no puede llamarse X" en el
  # momento de guardar, no después), y las POST pueden reaccionar al
  # cambio. Si el catálogo nunca definió esa transición, sigue el update
  # directo de siempre — 100% retrocompatible.
  def actualizar(registro, attrs) do
    schema_mod = registro.__struct__
    catalogo = schema_mod.__schema__(:source)
    transicion = MetadataApp.MetaStateEngine.transicion_guardar(catalogo, registro.estado_id)
    editables = MetadataApp.MetaStateEngine.campos_editables(catalogo, transicion)

    todos_los_campos =
      MetadataApp.BusinessProcessBuilder.MetaSchemaContext.listar_detalles(catalogo)
      |> Enum.map(& &1.schema_context_field)

    changeset =
      registro
      |> schema_mod.changeset(attrs)
      |> rechazar_no_editables(attrs, todos_los_campos, editables)
      |> Ecto.Changeset.change(%{update_guid: generar_guid()})

    if changeset.valid? do
      case transicion do
        nil -> Repo.update(changeset)
        transicion -> MetadataApp.MetaStateEngine.editar_con_transicion(changeset, transicion, attrs)
      end
    else
      {:error, changeset}
    end
  end

  # Rechaza explícitamente (error visible en el changeset, no ignorado en
  # silencio) cualquier intento de tocar un campo que no esté en la
  # whitelist de editables para el estado actual del registro. `estado_id`
  # y `trn`/`ulid` se protegen aparte porque no son campos "de negocio"
  # (no viven en meta_schema_detail, así que nunca aparecen en
  # `todos_los_campos`) — el único camino para cambiarlos es
  # `MetaStateEngine.ejecutar_transicion/3` y `MetadataApp.TRN`
  # respectivamente, nunca un PATCH.
  defp rechazar_no_editables(changeset, attrs, todos_los_campos, editables) do
    editables_set = MapSet.new(editables)
    protegidos = ["estado_id", "trn", "ulid" | todos_los_campos]

    attrs
    |> Map.keys()
    |> Enum.map(&to_string/1)
    |> Enum.filter(&(&1 in protegidos and &1 not in editables_set))
    |> Enum.reduce(changeset, fn campo, cs ->
      Ecto.Changeset.add_error(
        cs,
        String.to_existing_atom(campo),
        "no editable en el estado actual"
      )
    end)
  end

  def eliminar(registro) do
    registro
    |> Ecto.Changeset.change(%{delete_guid: generar_guid()})
    |> Repo.update()
  end

  # estados_por_id: %{estado_id => nombre} (ver MetaStateEngine.mapa_nombres_estados/1)
  # — opcional para no romper otros llamadores; sin él, o si el registro no
  # tiene estado_id asignado, no agrega estado_nombre.
  def serializar(registro, estados_por_id \\ %{}) do
    registro
    |> Map.from_struct()
    |> Map.drop([:__meta__, :insert_guid, :update_guid, :delete_guid])
    |> agregar_estado_nombre(estados_por_id)
  end

  # Reordena el mapa de serializar/2 para que el TRN quede siempre al final,
  # después del estado. Aparte de serializar/2 (que otros módulos internos
  # como CatalogoLive siguen usando como mapa plano) porque esto devuelve un
  # Jason.OrderedObject — solo debe usarse justo antes de json/2 en los
  # controllers, no como resultado de uso interno.
  def trn_al_final(mapa) do
    case Map.pop(mapa, :trn) do
      {nil, _mapa} -> mapa
      {trn, resto} -> Jason.OrderedObject.new(Map.to_list(resto) ++ [trn: trn])
    end
  end

  defp agregar_estado_nombre(%{estado_id: nil} = mapa, _estados_por_id), do: mapa

  defp agregar_estado_nombre(%{estado_id: estado_id} = mapa, estados_por_id) do
    Map.put(mapa, :estado_nombre, Map.get(estados_por_id, estado_id))
  end

  defp agregar_estado_nombre(mapa, _estados_por_id), do: mapa

  # Valida que el valor de `campo` no exista ya como `campo_externo` en
  # `tabla_externa` (unicidad cross-catálogo). `tabla_externa` es un nombre de
  # tabla, no un módulo — se consulta sin schema Ecto compilado.
  def validar_unico_en(changeset, campo, tabla_externa, campo_externo) do
    case Ecto.Changeset.get_change(changeset, campo) do
      nil ->
        changeset

      valor ->
        campo_externo_atom = String.to_existing_atom(campo_externo)

        existe? =
          Repo.exists?(
            from t in tabla_externa,
              where: field(t, ^campo_externo_atom) == ^valor,
              where: is_nil(field(t, :delete_guid))
          )

        if existe? do
          Ecto.Changeset.add_error(changeset, campo, "ya existe en #{tabla_externa}")
        else
          changeset
        end
    end
  end

  defp generar_guid do
    Ecto.UUID.generate() |> String.replace("-", "")
  end
end
