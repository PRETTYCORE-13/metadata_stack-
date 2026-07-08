defmodule MetadataApp.StateEngine do
  @moduledoc """
  Motor de Estados y Transiciones. Punto de entrada único: `ejecutar_transicion/3`.

  Agnóstico del catálogo: no sabe qué es un "cliente", solo sabe operar sobre
  cualquier struct Ecto de un catálogo generado (`MetadataApp.MetaCatalogoGenerico`)
  que tenga `:id` y `:estado_id`. Todo lo específico de negocio vive como datos
  en `meta_schema_estados`/`meta_schema_transiciones`/`meta_schema_transicion_reglas`,
  no en código.
  """

  import Ecto.Query
  alias Ecto.Multi
  alias MetadataApp.Repo
  alias MetadataApp.MetaSchemaContext
  alias MetadataApp.MetaSchema.{Header, Estado, Transicion, TransicionRegla, TransicionEvento}
  alias MetadataApp.StateEngine.Reglas

  @doc """
  registro: struct Ecto de un catálogo generado (necesita :id y :estado_id).
  accion: string, nombre de la acción de negocio (no el estado destino).
  contexto: mapa con llaves string (usuario/roles + datos adicionales, ej.
  %{"usuario_id" => 1, "motivo_baja" => "..."}).

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
         :ok <- evaluar_precondiciones(transicion, registro_actual, contexto) do
      ejecutar_nucleo(registro_actual, header, transicion, contexto)
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
      {transicion, evaluar_precondiciones_lista(transicion, registro_actual, contexto)}
    end)
    |> Enum.reject(fn {_transicion, fallas} ->
      Enum.any?(fallas, &(&1.regla == "requiere_rol"))
    end)
    |> Enum.map(fn {transicion, fallas} ->
      %{
        accion: transicion.accion,
        etiqueta: transicion.etiqueta,
        disponible: fallas == [],
        razones: fallas,
        requiere: requiere_de(transicion)
      }
    end)
  end

  @doc """
  Campos editables de `catalogo` (schema_context_name) para `estado_id`.
  Lee `editable_en` (lista de ids de `meta_schema_estados`) de
  `meta_schema_detail.schema_context_properties`.

  Semántica: si el catálogo NO adoptó el motor de estados (cero filas en
  `meta_schema_estados`), no se restringe nada — devuelve todos los campos
  del catálogo, para no romper retroactivamente catálogos que nunca usan
  este motor. Si SÍ lo adoptó, es fail-safe: un campo sin `editable_en`
  declarado, o cuyo `editable_en` no incluye `estado_id`, no es editable
  (incluye el caso `estado_id: nil` — un registro sin estado asignado no
  tiene ningún campo editable).
  """
  @spec campos_editables(String.t(), integer() | nil) :: [String.t()]
  def campos_editables(catalogo, estado_id) do
    detalles = MetaSchemaContext.listar_detalles(catalogo)

    if catalogo_adopto_motor?(catalogo) do
      detalles
      |> Enum.filter(fn detalle ->
        editable_en = Map.get(detalle.schema_context_properties || %{}, "editable_en", [])
        estado_id in editable_en
      end)
      |> Enum.map(& &1.schema_context_field)
    else
      Enum.map(detalles, & &1.schema_context_field)
    end
  end

  @doc """
  El estado inicial (`es_inicial: true`) configurado para `catalogo`, o `nil`
  si el catálogo no adoptó el motor de estados. Usado al crear un registro
  nuevo (`CatalogoGenerico.crear/2`) para que no nazca sin estado — un
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
            is_nil(t.delete_guid),
        preload: [reglas: ^reglas_query()]

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
            is_nil(t.delete_guid),
        preload: [reglas: ^reglas_query()]

    Repo.all(query)
  end

  defp reglas_query do
    from r in TransicionRegla, where: is_nil(r.delete_guid), order_by: r.orden
  end

  defp obtener_header!(modulo), do: obtener_header_por_nombre!(modulo.__schema__(:source))

  # --- Paso 2: precondiciones (solo lectura, sin cortocircuito) -------------

  defp evaluar_precondiciones(transicion, registro, contexto) do
    case evaluar_precondiciones_lista(transicion, registro, contexto) do
      [] -> :ok
      fallas -> {:error, {:precondiciones, fallas}}
    end
  end

  defp evaluar_precondiciones_lista(transicion, registro, contexto) do
    transicion.reglas
    |> Enum.filter(&(&1.tipo == "pre"))
    |> Enum.map(fn regla ->
      case Reglas.evaluar_precondicion(regla.regla, registro, contexto, regla.params) do
        :ok -> nil
        {:error, mensaje} -> %{regla: regla.regla, mensaje: mensaje}
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp requiere_de(transicion) do
    transicion.reglas
    |> Enum.filter(&(&1.tipo == "pre" and &1.regla == "dato_en_contexto"))
    |> Enum.map(fn regla ->
      dato = Map.get(regla.params, "dato")

      %{
        dato: dato,
        tipo: Map.get(regla.params, "tipo", "string"),
        etiqueta: Map.get(regla.params, "etiqueta", dato)
      }
    end)
  end

  # --- Pasos 3-5a: núcleo transaccional --------------------------------------

  defp ejecutar_nucleo(registro, header, transicion, contexto) do
    modulo = registro.__struct__
    estado_leido = registro.estado_id

    multi =
      Multi.new()
      |> Multi.run(:cambio_estado, fn repo, _changes ->
        actualizar_estado_con_lock(
          repo,
          modulo,
          registro.id,
          estado_leido,
          transicion.estado_destino_id
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
      |> agregar_postcondiciones_transaccionales(transicion, registro, contexto)

    case Repo.transaction(multi) do
      {:ok, _cambios} ->
        registro_final = Repo.get!(modulo, registro.id)
        despachar_efectos_de_cortesia(transicion, registro_final, contexto)
        {:ok, registro_final}

      {:error, :cambio_estado, :conflicto_concurrencia, _cambios} ->
        {:error, :conflicto_concurrencia}

      {:error, _paso, razon, _cambios} ->
        {:error, {:postcondicion_fallida, razon}}
    end
  end

  # Bloqueo optimista: el UPDATE solo pega si el estado sigue siendo el que
  # leímos en el Paso 1. Si otra transición ya corrió en el medio, filas
  # afectadas = 0 y abortamos todo el Multi.
  defp actualizar_estado_con_lock(repo, modulo, id, estado_leido, estado_destino_id) do
    query = from r in modulo, where: r.id == ^id and r.estado_id == ^estado_leido

    case repo.update_all(query, set: [estado_id: estado_destino_id]) do
      {1, _} -> {:ok, :actualizado}
      {0, _} -> {:error, :conflicto_concurrencia}
    end
  end

  defp agregar_postcondiciones_transaccionales(multi, transicion, registro, contexto) do
    transicion.reglas
    |> Enum.filter(&(&1.tipo == "post" and &1.transaccional))
    |> Enum.sort_by(& &1.orden)
    |> Enum.reduce(multi, fn regla, multi_acc ->
      Multi.run(multi_acc, {:post_transaccional, regla.id}, fn repo, _cambios ->
        Reglas.ejecutar_postcondicion(regla.regla, registro, contexto, regla.params, repo)
      end)
    end)
  end

  # --- Paso 5b: efectos de cortesía (después del commit) --------------------

  defp despachar_efectos_de_cortesia(transicion, registro, contexto) do
    transicion.reglas
    |> Enum.filter(&(&1.tipo == "post" and not &1.transaccional))
    |> Enum.sort_by(& &1.orden)
    |> Enum.each(fn regla ->
      Task.Supervisor.start_child(MetadataApp.StateEngine.TaskSupervisor, fn ->
        # Falla acá NUNCA revierte la transición ni llega al usuario — es
        # responsabilidad de la cola/reintentos, no del ciclo transaccional.
        Reglas.ejecutar_postcondicion(regla.regla, registro, contexto, regla.params, Repo)
      end)
    end)

    :ok
  end

  defp generar_guid do
    Ecto.UUID.generate() |> String.replace("-", "")
  end
end
