defmodule MetadataApp.MetaStateEngine do
  @moduledoc """
  Motor de Estados y Transiciones. Punto de entrada único: `ejecutar_transicion/3`.

  Agnóstico del catálogo: no sabe qué es un "cliente", solo sabe operar sobre
  cualquier struct Ecto de un catálogo generado (`MetadataApp.BusinessProcessBuilder.MetaCatalogoGenerico`)
  que tenga `:id` y `:estado_id`. La estructura del autómata (estados/
  transiciones) vive como datos en `meta_schema_estados`/`meta_schema_transiciones`.
  La lógica de negocio (PRE/POST) vive como código — un módulo Pre y un
  módulo Post por catálogo, ver `MetaStateEngine.Reglas`.
  """

  import Ecto.Query
  alias Ecto.Multi
  alias MetadataApp.Repo
  alias MetadataApp.BusinessProcessBuilder.MetaSchemaContext
  alias MetadataApp.BusinessProcessBuilder.MetaSchema.Header
  alias MetadataApp.MetaSchema.{Estado, Transicion, TransicionEvento}
  alias MetadataApp.MetaStateEngine.Reglas

  @doc """
  registro: struct Ecto de un catálogo generado (necesita :id y :estado_id).
  accion: string, nombre de la acción de negocio (no el estado destino).
  contexto: mapa con llaves string (usuario/roles + datos adicionales, ej.
  %{"usuario_id" => 1, "motivo_baja" => "..."}) — si la transición
  resuelta tiene `campos_editables`, las llaves de `contexto` que
  coincidan con esos campos TAMBIÉN se aplican como cambio de datos, en
  el mismo update atómico que el cambio de estado (agregado 2026-07-21:
  antes una transición común solo cambiaba `estado_id`, nunca campos de
  negocio, y la única puerta para editar campos era PATCH con una
  transición "guardar" self-loop — ver `construir_changeset_transicion/3`
  y `CatalogoGenerico.actualizar/2`, que sigue siendo el camino para
  ediciones que NO cambian de estado).

  Devuelve {:ok, registro_actualizado} | {:error, razon_estructurada}.
  """
  @spec ejecutar_transicion(struct(), String.t(), map()) :: {:ok, struct()} | {:error, term()}
  def ejecutar_transicion(registro, accion, contexto) when is_map(contexto) do
    modulo = registro.__struct__
    # Paso 1 (parte 1): el estado origen se lee AHORA de la base, nunca del
    # que el caller cree tener — protección contra pantallas desactualizadas.
    registro_actual = Repo.get!(modulo, registro.id)
    header = obtener_header!(modulo)

    with {:ok, transicion} <- resolver_transicion(header, registro_actual.estado_id, accion),
         {:ok, changeset} <- construir_changeset_transicion(registro_actual, transicion, contexto),
         :ok <- evaluar_precondiciones(transicion, Ecto.Changeset.apply_changes(changeset), contexto) do
      ejecutar_nucleo(changeset, header, transicion, contexto)
    end
  end

  # Si la transición no tiene campos_editables, es un changeset vacío (0
  # cambios) — mismo comportamiento de siempre, solo cambia estado_id. Si
  # los tiene, mismo criterio de whitelist que ya usa CatalogoGenerico
  # para PATCH (rechazo explícito, visible en el changeset, de cualquier
  # campo real que no esté en la whitelist — nunca en silencio).
  defp construir_changeset_transicion(registro, %Transicion{campos_editables: []}, _contexto) do
    {:ok, Ecto.Changeset.change(registro)}
  end

  defp construir_changeset_transicion(registro, %Transicion{campos_editables: editables}, contexto) do
    schema_mod = registro.__struct__
    catalogo = schema_mod.__schema__(:source)
    todos_los_campos = catalogo |> MetaSchemaContext.listar_detalles() |> Enum.map(& &1.schema_context_field)

    changeset =
      registro
      |> schema_mod.changeset(contexto)
      |> rechazar_no_editables_transicion(contexto, todos_los_campos, editables)

    if changeset.valid?, do: {:ok, changeset}, else: {:error, changeset}
  end

  defp rechazar_no_editables_transicion(changeset, contexto, todos_los_campos, editables) do
    editables_set = MapSet.new(editables)
    protegidos = ["estado_id" | todos_los_campos]

    contexto
    |> Map.keys()
    |> Enum.map(&to_string/1)
    |> Enum.filter(&(&1 in protegidos and &1 not in editables_set))
    |> Enum.reduce(changeset, fn campo, cs ->
      Ecto.Changeset.add_error(cs, String.to_existing_atom(campo), "no editable en esta transición")
    end)
  end

  @doc """
  Alta con motor de estados: variante de `ejecutar_transicion/3` para cuando
  el registro TODAVÍA NO EXISTE. Corre el mismo ciclo de 5 pasos —
  precondiciones sin cortocircuito, "cambio de estado" (acá un INSERT en vez
  de un UPDATE con lock optimista, no hay fila previa que bloquear), evento
  inmutable (con `estado_origen_id: nil`), postcondiciones transaccionales,
  efectos de cortesía post-commit — reusando el mismo vocabulario de 8
  reglas. `attrs`/`contexto` son el mismo mapa: los campos del registro Y el
  contexto de negocio (ej. `usuario_id`, datos que pida `dato_en_contexto`)
  llegan juntos en el body del POST de creación.

  Solo se invoca cuando `transicion_alta/1` ya encontró una transición
  configurada — `BusinessProcessBuilder.CatalogoGenerico.crear/2` decide eso, no este módulo.
  """
  @spec dar_de_alta(module(), map(), Transicion.t(), map()) :: {:ok, struct()} | {:error, term()}
  def dar_de_alta(schema_mod, attrs, %Transicion{} = transicion, contexto) when is_map(contexto) do
    with {:ok, changeset} <- construir_changeset_valido(schema_mod, attrs),
         :ok <- evaluar_precondiciones(transicion, Ecto.Changeset.apply_changes(changeset), contexto) do
      ejecutar_nucleo_alta(changeset, transicion, contexto)
    end
  end

  @doc """
  La transición de alta (`accion: "alta"`, `estado_origen_id: nil`)
  configurada para `catalogo`, o `nil` si el catálogo no definió una. Es la
  convención: un catálogo "nace" a través de la transición cuya `accion` es
  literalmente `"alta"` — `BusinessProcessBuilder.CatalogoGenerico.crear/2` la busca por este
  nombre fijo, igual que `estado_inicial/1` busca `es_inicial: true`.
  """
  @spec transicion_alta(String.t()) :: Transicion.t() | nil
  def transicion_alta(catalogo) do
    header = obtener_header_por_nombre!(catalogo)

    Repo.one(
      from t in Transicion,
        where:
          t.meta_schema_header_id == ^header.id and is_nil(t.estado_origen_id) and
            t.accion == "alta" and is_nil(t.delete_guid)
    )
  end

  @doc """
  Transición "guardar" (self-loop: `estado_origen_id == estado_destino_id
  == estado_id`) configurada para `catalogo` en el estado actual del
  registro, o `nil` si no existe. Convención análoga a `transicion_alta/1`
  — `BusinessProcessBuilder.CatalogoGenerico.actualizar/2` la busca por este nombre fijo para
  decidir si una edición de campos (PUT/PATCH) corre el ciclo de reglas o
  sigue el update directo de siempre.
  """
  @spec transicion_guardar(String.t(), integer() | nil) :: Transicion.t() | nil
  def transicion_guardar(_catalogo, nil), do: nil

  def transicion_guardar(catalogo, estado_id) do
    header = obtener_header_por_nombre!(catalogo)

    Repo.one(
      from t in Transicion,
        where:
          t.meta_schema_header_id == ^header.id and t.accion == "guardar" and
            t.estado_origen_id == ^estado_id and t.estado_destino_id == ^estado_id and
            is_nil(t.delete_guid)
    )
  end

  @doc """
  Edición con motor de estados: variante de `ejecutar_transicion/3` para
  cuando la "transición" en realidad es un cambio de campos (self-loop
  `"guardar"`, ver `transicion_guardar/2`). Diferencia clave con una
  transición común: las PRE evalúan contra los valores YA PROPUESTOS
  (`changeset` aplicado), no los que había guardados — así una regla como
  "no puede llamarse X" bloquea la edición ahí mismo, no un guardar
  posterior. `changeset` ya viene validado (campos editables, tipos, etc.)
  por `BusinessProcessBuilder.CatalogoGenerico.actualizar/2` — acá solo se agrega el ciclo.
  """
  @spec editar_con_transicion(Ecto.Changeset.t(), Transicion.t(), map()) ::
          {:ok, struct()} | {:error, term()}
  def editar_con_transicion(changeset, %Transicion{} = transicion, contexto) when is_map(contexto) do
    with :ok <- evaluar_precondiciones(transicion, Ecto.Changeset.apply_changes(changeset), contexto) do
      ejecutar_nucleo_editar(changeset, transicion, contexto)
    end
  end

  @doc """
  Descubrimiento (Contrato 1 con el frontend): para el registro y su estado
  actual, lista las transiciones disponibles desde ahí con el resultado de
  evaluar sus precondiciones — reutiliza el mismo paso 2 del ciclo, sin
  duplicar lógica. No muta nada.

  Fallas de `requiere_rol` OCULTAN la transición por completo (ni siquiera
  se informa que existe); cualquier otra falla la deja en la lista pero
  `disponible: false`, con `razones` para mostrar en la UI.
  """
  def transiciones_disponibles(registro, contexto \\ %{}) do
    modulo = registro.__struct__
    registro_actual = Repo.get!(modulo, registro.id)
    header = obtener_header!(modulo)

    header.id
    |> transiciones_desde(registro_actual.estado_id)
    |> Enum.map(fn transicion ->
      razones = evaluar_precondiciones_lista(transicion, registro_actual, contexto)

      %{
        accion: transicion.accion,
        etiqueta: transicion.etiqueta,
        disponible: razones == [],
        razones: razones
      }
    end)
  end

  @doc """
  Campos editables de `catalogo` (schema_context_name) para la `transicion`
  de edición que se va a ejecutar (típicamente la resuelta por
  `transicion_guardar/2`) — lee `campos_editables` directo de esa
  transición, ya no de `meta_schema_detail.schema_context_properties`
  (convención `editable_en` vieja, indexada por estado en vez de por
  transición: no distinguía dos formas distintas de editar desde el mismo
  estado).

  Semántica: si el catálogo NO adoptó el motor de estados (cero filas en
  `meta_schema_estados`), no se restringe nada — devuelve todos los campos
  del catálogo, para no romper retroactivamente catálogos que nunca usan
  este motor. Si SÍ lo adoptó, es fail-safe: sin una transición de edición
  resuelta (`transicion: nil` — no hay `guardar` configurado para el estado
  actual, o el registro no tiene estado), no hay ningún campo editable.
  """
  @spec campos_editables(String.t(), Transicion.t() | nil) :: [String.t()]
  def campos_editables(catalogo, transicion) do
    if catalogo_adopto_motor?(catalogo) do
      case transicion do
        nil -> []
        %Transicion{campos_editables: campos} -> campos
      end
    else
      catalogo
      |> MetaSchemaContext.listar_detalles()
      |> Enum.map(& &1.schema_context_field)
    end
  end

  @doc """
  El estado inicial (`es_inicial: true`) configurado para `catalogo`, o `nil`
  si el catálogo no adoptó el motor de estados. Usado al crear un registro
  nuevo (`BusinessProcessBuilder.CatalogoGenerico.crear/2`) para que no nazca sin estado — un
  registro con `estado_id: nil` no puede transicionar a ningún lado (ninguna
  transición tiene `estado_origen_id: nil`) ni editar ningún campo
  (`campos_editables/2` no permite nada para `estado_id: nil`).
  """
  @spec estado_inicial(String.t()) :: struct() | nil
  def estado_inicial(catalogo) do
    header = obtener_header_por_nombre!(catalogo)

    Repo.one(
      from e in Estado,
        where:
          e.meta_schema_header_id == ^header.id and e.es_inicial == true and is_nil(e.delete_guid)
    )
  end

  @doc """
  Mapa `%{estado_id => nombre}` de todos los estados de `catalogo` — para
  enriquecer la serialización de datos con el nombre legible del estado
  (`BusinessProcessBuilder.CatalogoGenerico.serializar/2`) sin hacer una query por fila.
  """
  @spec mapa_nombres_estados(String.t()) :: %{integer() => String.t()}
  def mapa_nombres_estados(catalogo) do
    header = obtener_header_por_nombre!(catalogo)

    from(e in Estado,
      where: e.meta_schema_header_id == ^header.id and is_nil(e.delete_guid),
      select: {e.id, e.nombre}
    )
    |> Repo.all()
    |> Map.new()
  end

  defp catalogo_adopto_motor?(catalogo) do
    header = obtener_header_por_nombre!(catalogo)

    Repo.exists?(
      from e in Estado, where: e.meta_schema_header_id == ^header.id and is_nil(e.delete_guid)
    )
  end

  defp obtener_header_por_nombre!(catalogo),
    do: Repo.get_by!(Header, schema_context_name: catalogo)

  # --- Paso 1: resolución estructural ---------------------------------------

  defp resolver_transicion(header, estado_actual_id, accion) do
    query =
      from t in Transicion,
        where:
          t.meta_schema_header_id == ^header.id and
            t.estado_origen_id == ^estado_actual_id and
            t.accion == ^accion and
            is_nil(t.delete_guid)

    case Repo.one(query) do
      nil -> {:error, {:transicion_invalida, %{estado_actual_id: estado_actual_id}}}
      transicion -> {:ok, transicion}
    end
  end

  defp transiciones_desde(header_id, estado_actual_id) do
    query =
      from t in Transicion,
        where:
          t.meta_schema_header_id == ^header_id and
            t.estado_origen_id == ^estado_actual_id and
            is_nil(t.delete_guid)

    Repo.all(query)
  end

  defp obtener_header!(modulo), do: obtener_header_por_nombre!(modulo.__schema__(:source))

  # --- Paso 2: precondiciones (solo lectura) --------------------------------
  # Un solo código PRE por catálogo (ver MetaStateEngine.Reglas) — a
  # diferencia del viejo mecanismo de varias filas sin cortocircuito, acá
  # hay como mucho UN mensaje de error (el que el código del catálogo haya
  # devuelto). Ya no existe requiere_de/1 (aviso previo de "qué datos hacen
  # falta" antes de intentar) — con código libre no hay forma de inferirlo
  # sin ejecutar; queda como responsabilidad del desarrollador documentarlo
  # aparte si hace falta.

  defp evaluar_precondiciones(transicion, registro, contexto) do
    case evaluar_precondiciones_lista(transicion, registro, contexto) do
      [] -> :ok
      fallas -> {:error, {:precondiciones, fallas}}
    end
  end

  defp evaluar_precondiciones_lista(transicion, registro, contexto) do
    case Reglas.evaluar_pre(transicion.accion, registro, contexto) do
      :ok -> []
      {:error, mensaje} -> [%{regla: "pre", mensaje: mensaje}]
    end
  end

  # --- Núcleo transaccional del alta y de la edición (paralelo a ejecutar_nucleo/4) ---

  defp construir_changeset_valido(schema_mod, attrs) do
    changeset =
      schema_mod
      |> struct()
      |> schema_mod.changeset(attrs)
      |> Ecto.Changeset.change(%{insert_guid: generar_guid()})

    if changeset.valid?, do: {:ok, changeset}, else: {:error, changeset}
  end

  defp ejecutar_nucleo_alta(changeset, transicion, contexto) do
    schema_mod = changeset.data.__struct__
    changeset_final = Ecto.Changeset.change(changeset, %{estado_id: transicion.estado_destino_id})

    multi =
      Multi.new()
      |> Multi.insert(:registro, changeset_final)
      |> Multi.insert(:evento, fn %{registro: registro} ->
        TransicionEvento.changeset(%TransicionEvento{}, %{
          meta_schema_header_id: transicion.meta_schema_header_id,
          registro_id: registro.id,
          estado_origen_id: nil,
          estado_destino_id: transicion.estado_destino_id,
          accion: transicion.accion,
          usuario_id: Map.get(contexto, "usuario_id"),
          contexto: contexto,
          insert_guid: generar_guid()
        })
      end)
      |> agregar_postcondicion_multi(transicion, contexto)

    case Repo.transaction(multi) do
      {:ok, %{registro: registro}} ->
        {:ok, Repo.get!(schema_mod, registro.id)}

      {:error, :registro, changeset, _cambios} ->
        {:error, changeset}

      {:error, _paso, razon, _cambios} ->
        {:error, {:postcondicion_fallida, razon}}
    end
  end

  # Un solo código POST por catálogo (ver MetaStateEngine.Reglas) — corre
  # SIEMPRE dentro de la transacción (mismo comportamiento que antes tenía
  # `transaccional: true`; el viejo "efecto de cortesía" async ya no existe
  # acá, ver ReglaPost).
  defp agregar_postcondicion_multi(multi, transicion, contexto) do
    Multi.run(multi, :post, fn repo, %{registro: registro} ->
      Reglas.ejecutar_post(transicion.accion, registro, contexto, repo)
    end)
  end

  defp ejecutar_nucleo_editar(changeset, transicion, contexto) do
    schema_mod = changeset.data.__struct__

    multi =
      Multi.new()
      |> Multi.update(:registro, changeset)
      |> Multi.insert(:evento, fn %{registro: registro} ->
        TransicionEvento.changeset(%TransicionEvento{}, %{
          meta_schema_header_id: transicion.meta_schema_header_id,
          registro_id: registro.id,
          estado_origen_id: transicion.estado_origen_id,
          estado_destino_id: transicion.estado_destino_id,
          accion: transicion.accion,
          usuario_id: Map.get(contexto, "usuario_id"),
          contexto: contexto,
          insert_guid: generar_guid()
        })
      end)
      |> agregar_postcondicion_multi(transicion, contexto)

    case Repo.transaction(multi) do
      {:ok, %{registro: registro}} ->
        {:ok, Repo.get!(schema_mod, registro.id)}

      {:error, :registro, changeset, _cambios} ->
        {:error, changeset}

      {:error, _paso, razon, _cambios} ->
        {:error, {:postcondicion_fallida, razon}}
    end
  end

  # --- Pasos 3-5a: núcleo transaccional --------------------------------------

  # `changeset` trae los cambios de campo YA validados y restringidos a
  # campos_editables (vacío si la transición no tiene ninguno) —
  # construir_changeset_transicion/3 lo arma antes de llegar acá.
  defp ejecutar_nucleo(changeset, header, transicion, contexto) do
    registro = changeset.data
    modulo = registro.__struct__
    estado_leido = registro.estado_id
    cambios_campos = Keyword.new(changeset.changes)

    multi =
      Multi.new()
      |> Multi.run(:cambio_estado, fn repo, _changes ->
        actualizar_estado_con_lock(
          repo,
          modulo,
          registro.id,
          estado_leido,
          transicion.estado_destino_id,
          cambios_campos
        )
      end)
      |> Multi.insert(:evento, fn _changes ->
        TransicionEvento.changeset(%TransicionEvento{}, %{
          meta_schema_header_id: header.id,
          registro_id: registro.id,
          estado_origen_id: estado_leido,
          estado_destino_id: transicion.estado_destino_id,
          accion: transicion.accion,
          usuario_id: Map.get(contexto, "usuario_id"),
          contexto: contexto,
          insert_guid: generar_guid()
        })
      end)
      |> agregar_postcondicion(transicion, modulo, registro.id, contexto)

    case Repo.transaction(multi) do
      {:ok, _cambios} ->
        {:ok, Repo.get!(modulo, registro.id)}

      {:error, :cambio_estado, :conflicto_concurrencia, _cambios} ->
        {:error, :conflicto_concurrencia}

      {:error, _paso, razon, _cambios} ->
        {:error, {:postcondicion_fallida, razon}}
    end
  end

  # Bloqueo optimista: el UPDATE solo pega si el estado sigue siendo el que
  # leímos en el Paso 1 — si otra transición ya corrió en el medio, filas
  # afectadas = 0 y abortamos todo el Multi. `cambios_campos` (agregado
  # 2026-07-21) viaja en el mismo SET que estado_id — un único UPDATE
  # atómico, no dos pasos separados.
  defp actualizar_estado_con_lock(repo, modulo, id, estado_leido, estado_destino_id, cambios_campos) do
    query = from r in modulo, where: r.id == ^id and r.estado_id == ^estado_leido
    set = [estado_id: estado_destino_id] ++ cambios_campos

    case repo.update_all(query, set: set) do
      {1, _} -> {:ok, :actualizado}
      {0, _} -> {:error, :conflicto_concurrencia}
    end
  end

  # Re-lee el registro YA actualizado (a diferencia de antes de 2026-07-21,
  # que pasaba el struct pre-transición por closure): con campos_editables
  # aplicándose en esta misma transición, POST tiene que ver los valores
  # nuevos, no los viejos — mismo criterio que ya usaba
  # ejecutar_nucleo_editar/3 para el self-loop "guardar".
  defp agregar_postcondicion(multi, transicion, modulo, id, contexto) do
    Multi.run(multi, :post, fn repo, _cambios ->
      registro_actualizado = repo.get!(modulo, id)
      Reglas.ejecutar_post(transicion.accion, registro_actualizado, contexto, repo)
    end)
  end

  defp generar_guid do
    Ecto.UUID.generate() |> String.replace("-", "")
  end
end
