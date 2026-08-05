defmodule MetadataApp.BusinessProcessBuilder.CatalogoGenerico do
  alias MetadataApp.Repo
  import Ecto.Query

  # filtros: %{"campo" => valor, ...} — combinados con AND, solo columnas
  # reales de la tabla (no campos calculados como estado_nombre). Usado por
  # MetaBcApi.listar/2 para que una regla de negocio pueda filtrar otro
  # catálogo sin escribir la query a mano. `valor` acepta también una tupla
  # con operador — {:ilike, texto}, {:gte, valor}, {:lte, valor},
  # {:entre, {desde, hasta}} (cualquiera de los dos puede ir nil, ej.
  # {:entre, {100, nil}} es "desde 100 en adelante") — usado por
  # CatalogoLive para los filtros dinámicos por columna. Un valor plano
  # (no tupla) sigue siendo igualdad exacta, como siempre.
  #
  # opciones: [] por default — sin :limit/:offset trae TODO, el
  # comportamiento de siempre. MetaBcApi.listar/2 sigue llamando sin
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

  # Agregación (suma/promedio/mínimo/máximo/conteo) de una columna
  # numérica sobre TODAS las filas que matchean filtros/búsqueda — no
  # solo la página actual (ver "Resumen" en CatalogoLive). `funcion` es
  # uno de :sum/:avg/:min/:max/:count, el mismo vocabulario que acepta
  # Repo.aggregate/3 nativo — sin reinventar nada acá, solo reusar el
  # mismo filtrado que ya usan listar/3 y contar/3.
  def agregar(schema_mod, campo, funcion, filtros \\ %{}, busqueda \\ nil) do
    campo_atom = String.to_existing_atom(to_string(campo))

    from(r in schema_mod, where: is_nil(r.delete_guid))
    |> aplicar_filtros(filtros)
    |> aplicar_busqueda(busqueda)
    |> Repo.aggregate(funcion, campo_atom)
  end

  # Público (no defp) — MetaConsultas.ejecutar/3 reusa exactamente esta
  # misma semántica de filtros para las Consultas Ecto (banda de filtros
  # idéntica a la de cualquier catálogo, en vez de reinventarla).
  def aplicar_filtros(query, filtros) do
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

  # Pertenencia a una lista — usado por CatalogoLive para el filtro
  # "por default" de fecha de alta (ver MetaAuditoria.ids_creados_en_rango/3):
  # como los catálogos generados no tienen columna de timestamp propia, se
  # resuelve la lista de :id por afuera (vía auditoría) y se filtra acá.
  defp aplicar_filtro(query, campo, {:en, lista}) do
    from(r in query, where: field(r, ^campo) in ^lista)
  end

  defp aplicar_filtro(query, campo, valor) do
    from(r in query, where: field(r, ^campo) == ^valor)
  end

  def aplicar_busqueda(query, nil), do: query
  def aplicar_busqueda(query, {texto, _campos}) when texto in [nil, ""], do: query

  def aplicar_busqueda(query, {texto, campos}) do
    patron = "%#{texto}%"

    condicion =
      Enum.reduce(campos, dynamic(false), fn campo, acc ->
        campo_atom = String.to_existing_atom(to_string(campo))
        dynamic([r], ^acc or fragment("?::text ILIKE ?", field(r, ^campo_atom), ^patron))
      end)

    from(r in query, where: ^condicion)
  end

  def aplicar_paginacion(query, opciones) do
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
  #
  # Catálogo Maestro-Detalle (R6, alta atómica): `opciones[:renglones]`
  # (mapa `%{"catalogo_detalle" => [attrs, ...]}`, default `%{}`) crea los
  # renglones iniciales del maestro en el MISMO ciclo — ver
  # `MetadataApp.Renglones.crear_todos/3`. `%{}` = comportamiento 100%
  # igual que siempre para cualquier catálogo sin detalles.
  def crear(schema_mod, attrs, opciones \\ []) do
    catalogo = schema_mod.__schema__(:source)
    renglones_spec = Keyword.get(opciones, :renglones, %{})
    contexto = Keyword.get(opciones, :contexto, %{})

    resultado =
      case MetadataApp.MetaStateEngine.transicion_alta(catalogo) do
        nil -> crear_simple(schema_mod, attrs, renglones_spec)
        transicion -> MetadataApp.MetaStateEngine.dar_de_alta(schema_mod, attrs, transicion, attrs, renglones_spec)
      end

    # PrettyCore TRN (Fase 1) — Regla #1: ninguna operación transaccional
    # nace sin TRN. Corre DESPUÉS del insert (no en el mismo changeset)
    # para no acoplar MetadataApp.MetaStateEngine —deliberadamente
    # agnóstico del catálogo— a este concepto de negocio. Sin ventana
    # observable desde afuera: crear/2 no devuelve el registro hasta que
    # esto termina. No hace nada si el catálogo no es transaccional.
    resultado
    |> MetadataApp.TRN.asignar_si_transaccional()
    |> auditar_alta(catalogo, contexto)
  end

  # Auditoría de DATOS (roadmap #6) — mismo criterio de "corre DESPUÉS,
  # como paso separado" que TRN.asignar_si_transaccional/1 de arriba: no
  # queda anidado en la misma transacción SQL que crear_simple/3 (ni la
  # de dar_de_alta/5, que vive en MetaStateEngine) — aceptable porque ya
  # es exactamente el mismo nivel de no-atomicidad que TRN acepta hoy
  # para el mismo insert, no una garantía nueva que se está bajando.
  defp auditar_alta({:ok, registro} = resultado, catalogo, contexto) do
    MetadataApp.MetaAuditoria.registrar(
      catalogo,
      "alta",
      registro.insert_guid,
      registro,
      %{"despues" => serializar(registro)},
      contexto
    )

    resultado
  end

  defp auditar_alta(error, _catalogo, _contexto), do: error

  # Envuelto en Repo.transaction/1 (aunque un solo Repo.insert/1 ya sería
  # atómico por sí mismo) porque MetadataApp.Renglones.preparar/3 puede
  # necesitar un SELECT ... FOR UPDATE previo sobre la fila del maestro
  # (catálogos detalle) que tiene que quedar en la MISMA transacción que el
  # insert final — para un catálogo que no es detalle, es un no-op extra
  # sin costo real. Devuelve el mismo shape de siempre ({:ok, registro} |
  # {:error, changeset}), Repo.transaction/1 solo envuelve, no lo cambia.
  # `renglones_spec` (Fase 6, R6): después del insert, crea los renglones
  # iniciales de ESTE registro (si tiene catálogos detalle) — mismo
  # aplanado de transacción anidada que ya describe el moduledoc de
  # `MetadataApp.Renglones`.
  defp crear_simple(schema_mod, attrs, renglones_spec) do
    catalogo = schema_mod.__schema__(:source)
    estado_inicial = MetadataApp.MetaStateEngine.estado_inicial(catalogo)

    Repo.transaction(fn ->
      resultado =
        schema_mod
        |> struct()
        |> schema_mod.changeset(attrs)
        |> Ecto.Changeset.change(%{insert_guid: generar_guid()})
        |> asignar_estado_inicial(estado_inicial)
        |> MetadataApp.Renglones.preparar(catalogo, attrs)
        |> Repo.insert()

      case resultado do
        {:ok, registro} ->
          case MetadataApp.Renglones.crear_todos(catalogo, registro.id, renglones_spec) do
            {:ok, _renglones} -> registro
            {:error, motivo} -> Repo.rollback(motivo)
          end

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
  end

  # Si el catálogo adoptó el motor de estados, todo registro nuevo nace en
  # su estado inicial — si no, no hay nada que asignar (estado_id queda nil,
  # como siempre para catálogos sin motor de estados).
  defp asignar_estado_inicial(changeset, nil), do: changeset

  defp asignar_estado_inicial(changeset, estado_inicial),
    do: Ecto.Changeset.change(changeset, %{estado_id: estado_inicial.id})

  # Crea varios registros del mismo catálogo en una sola transacción.
  # Si alguno falla, se revierten todos (todo o nada). Cada item puede
  # traer su propia "renglones" (R6) — un lote de maestros, cada uno con
  # sus propios renglones iniciales.
  def crear_muchos(schema_mod, lista_attrs, contexto \\ %{}) when is_list(lista_attrs) do
    Repo.transaction(fn ->
      Enum.map(lista_attrs, fn item ->
        {renglones, attrs} = Map.pop(item, "renglones", %{})

        case crear(schema_mod, attrs, renglones: renglones, contexto: contexto) do
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
  #
  # CompliancePty (docs/compliance-pty.md, C6): un catálogo detalle NUNCA
  # acepta PUT/PATCH directo — bug real encontrado en producción antes de
  # esta guarda: campos_editables/2 mira SI EL CATÁLOGO adoptó el motor
  # consultando SUS PROPIOS meta_schema_estados, que un catálogo detalle
  # nunca tiene (viven en el maestro, R3) — así que lo trataba como "sin
  # motor" y dejaba editar CUALQUIER campo sin pasar por ninguna
  # transición, sin campos_editables, sin evento de auditoría. La única
  # forma de tocar un campo de un renglón es una transición del maestro
  # con "renglones" (R4) — mismo criterio que ya usa eliminar/1 para
  # bloquear el DELETE de un renglón (R12).
  def actualizar(registro, attrs, contexto \\ %{}) do
    schema_mod = registro.__struct__
    catalogo = schema_mod.__schema__(:source)
    header = MetadataApp.BusinessProcessBuilder.MetaSchemaContext.obtener_header_por_nombre(catalogo)

    if header && header.schema_encabezado_id do
      {:error,
       "los campos de un renglón de un catálogo detalle no se editan por PUT/PATCH directo — use una transición del maestro con \"renglones\""}
    else
      antes = serializar(registro)

      # Mismo lookup que actualizar_directo/4 hace por su cuenta para
      # decidir el ciclo de reglas — repetirlo acá (barato, un SELECT) es
      # más simple que cambiar el contrato de retorno de esa función solo
      # para poder etiquetar la auditoría con el nombre de la transición.
      operacion =
        case MetadataApp.MetaStateEngine.transicion_guardar(catalogo, registro.estado_id) do
          nil -> "edicion"
          transicion -> "transicion:#{transicion.accion}"
        end

      registro
      |> actualizar_directo(attrs, schema_mod, catalogo)
      |> auditar_edicion(catalogo, operacion, antes, contexto)
    end
  end

  defp auditar_edicion({:ok, registro} = resultado, catalogo, operacion, antes, contexto) do
    MetadataApp.MetaAuditoria.registrar(
      catalogo,
      operacion,
      registro.update_guid,
      registro,
      %{"antes" => antes, "despues" => serializar(registro)},
      contexto
    )

    resultado
  end

  defp auditar_edicion(error, _catalogo, _operacion, _antes, _contexto), do: error

  defp actualizar_directo(registro, attrs, schema_mod, catalogo) do
    transicion = MetadataApp.MetaStateEngine.transicion_guardar(catalogo, registro.estado_id)

    detalles = MetadataApp.BusinessProcessBuilder.MetaSchemaContext.listar_detalles(catalogo)
    todos_los_campos = Enum.map(detalles, & &1.schema_context_field)

    # La propiedad "editable" del contrato (fija, por campo) manda además
    # de — no en vez de — la whitelist que arma el motor de estados: un
    # campo solo se puede tocar si pasa las dos restricciones.
    campos_editables_contrato =
      detalles
      |> Enum.filter(&(&1.schema_context_properties["editable"] == true))
      |> Enum.map(& &1.schema_context_field)

    editables =
      catalogo
      |> MetadataApp.MetaStateEngine.campos_editables(transicion)
      |> Enum.filter(&(&1 in campos_editables_contrato))

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

  # R12 del Maestro-Detalle: un renglón de un catálogo detalle nunca se
  # borra (ni soft-delete) — el único camino para "sacarlo" es una
  # transición del autómata a un estado tipo Cancelado. `header` se
  # resuelve por nombre de tabla (mismo patrón que MetadataApp.TRN), no
  # por una función exportada por el schema — evita otro mecanismo de
  # "preguntarle al módulo" aparte del que ya existe.
  def eliminar(registro, contexto \\ %{}) do
    catalogo = registro.__struct__.__schema__(:source)
    header = MetadataApp.BusinessProcessBuilder.MetaSchemaContext.obtener_header_por_nombre(catalogo)

    if header && header.schema_encabezado_id do
      {:error,
       "los renglones de un catálogo detalle no se borran — use una transición del autómata para pasarlo a un estado tipo \"Cancelado\""}
    else
      antes = serializar(registro)

      registro
      |> Ecto.Changeset.change(%{delete_guid: generar_guid()})
      |> Repo.update()
      |> auditar_baja(catalogo, antes, contexto)
    end
  end

  defp auditar_baja({:ok, registro} = resultado, catalogo, antes, contexto) do
    MetadataApp.MetaAuditoria.registrar(catalogo, "baja", registro.delete_guid, registro, %{"antes" => antes}, contexto)
    resultado
  end

  defp auditar_baja(error, _catalogo, _antes, _contexto), do: error

  # estados_por_id: %{estado_id => nombre} (ver MetaStateEngine.mapa_nombres_estados/1)
  # — opcional para no romper otros llamadores; sin él, o si el registro no
  # tiene estado_id asignado, no agrega estado_nombre.
  #
  # acompanamiento: %{campo => %{id_referenciado => %{...}}} (ver
  # mapa_acompanamiento/2) — opcional, mismo motivo. Reemplaza el id crudo
  # de un campo tipo "referencia" por el objeto resuelto, ej.
  # %{cliente_ecc: 1} -> %{cliente_ecc: %{id: 1, razon_social: "..."}}.
  def serializar(registro, estados_por_id \\ %{}, acompanamiento \\ %{}) do
    registro
    |> Map.from_struct()
    |> Map.drop([:__meta__, :insert_guid, :update_guid, :delete_guid])
    |> agregar_estado_nombre(estados_por_id)
    |> agregar_acompanamiento(acompanamiento)
  end

  # Arma, para cada campo tipo "referencia" con "campo_visualizacion" o
  # "campos_acompanamiento" configurado, un mapa %{id_referenciado =>
  # etiqueta} usando SOLO los ids que de verdad aparecen en `filas` — una
  # query batch por relación por página de resultados, nunca una query
  # por fila (mismo espíritu que MetaStateEngine.mapa_nombres_estados/1
  # para estado_nombre). La etiqueta se arma con etiqueta_para_referencia/2
  # — la misma función que ya usa opciones_referencia/1 para el picker de
  # FichaLive — para que la tabla y el formulario muestren siempre lo
  # mismo, sin un segundo mecanismo que se pueda desincronizar del
  # primero (bug real: acá solo se chequeaba campos_acompanamiento, así
  # que un campo configurado con el modo nuevo campo_visualizacion
  # quedaba mostrando el id crudo solo en la tabla).
  def mapa_acompanamiento(catalogo, filas) do
    catalogo
    |> MetadataApp.BusinessProcessBuilder.MetaSchemaContext.listar_detalles()
    |> Enum.filter(&campo_con_acompanamiento?/1)
    |> Map.new(fn detalle ->
      campo = String.to_existing_atom(detalle.schema_context_field)
      props = detalle.schema_context_properties
      modulo_destino = MetadataApp.BusinessProcessBuilder.MetaSchemaContext.modulo_por_nombre(props["catalogo"])

      ids =
        filas
        |> Enum.map(&Map.get(&1, campo))
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()

      {campo, resolver_acompanamiento(modulo_destino, ids, props)}
    end)
  end

  defp campo_con_acompanamiento?(detalle) do
    props = detalle.schema_context_properties || %{}

    props["tipo"] == "referencia" and
      ((is_map(props["campo_visualizacion"]) and props["campo_visualizacion"] != %{}) or
         (is_list(props["campos_acompanamiento"]) and props["campos_acompanamiento"] != []))
  end

  # Opciones para el <select> de un campo tipo "referencia" en
  # CampoInputComponents.campo_input/1 (picker simple, sin búsqueda) — TODOS
  # los registros del catálogo destino, con la etiqueta armada por
  # etiqueta_para_referencia/2: prioriza "campo_visualizacion" (BcMotorLive →
  # Relaciones → Configuración de visualización) si está configurado, y si
  # no cae al join de "campos_acompanamiento" de siempre (retrocompatible,
  # sin migración de datos — ver validar_campo_visualizacion/1 en
  # MetaSchemaContext). Tope de 500 registros a propósito: un <select> con
  # más opciones que eso deja de ser usable de todos modos (búsqueda con
  # filtro real es Fase 2, ver docs/roadmap-campos-acompanamiento.md).
  def opciones_referencia(props) do
    case MetadataApp.BusinessProcessBuilder.MetaSchemaContext.modulo_por_nombre(props["catalogo"]) do
      nil -> []
      modulo -> modulo |> listar(%{}, limit: 500) |> Enum.map(&{&1.id, etiqueta_para_referencia(&1, props)})
    end
  end

  @doc "Pública para la vista previa en vivo del panel de Relaciones (BcMotorLive)."
  def etiqueta_para_referencia(registro, %{"campo_visualizacion" => %{} = config}), do: etiqueta_con_visualizacion(registro, config)
  def etiqueta_para_referencia(registro, props), do: etiqueta_opcion_referencia(registro, props["campos_acompanamiento"])

  defp etiqueta_con_visualizacion(registro, %{"modo" => "descripcion", "campo_descripcion" => campo}) do
    valor_campo(registro, campo) || "##{registro.id}"
  end

  defp etiqueta_con_visualizacion(registro, %{"modo" => "codigo_descripcion"} = config) do
    [valor_campo(registro, config["campo_codigo"]), valor_campo(registro, config["campo_descripcion"])]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> "##{registro.id}"
      partes -> Enum.join(partes, " - ")
    end
  end

  defp etiqueta_con_visualizacion(registro, %{"modo" => "plantilla", "plantilla" => plantilla}) when is_binary(plantilla) do
    sustituir_variables(plantilla, registro)
  end

  defp etiqueta_con_visualizacion(registro, %{"modo" => "calculado", "formula" => formula}) when is_binary(formula) do
    valores = registro |> Map.from_struct() |> Map.new(fn {campo, valor} -> {Atom.to_string(campo), valor} end)

    case MetadataApp.MetaPlantillas.Formula.evaluar(formula, valores) do
      {:ok, resultado} -> to_string(resultado)
      {:error, _motivo} -> "##{registro.id}"
    end
  end

  defp etiqueta_con_visualizacion(registro, _config), do: "##{registro.id}"

  defp valor_campo(_registro, nil), do: nil

  defp valor_campo(registro, campo) do
    case Map.get(registro, safe_atom(campo)) do
      valor when valor in [nil, ""] -> nil
      valor -> to_string(valor)
    end
  end

  # "{campo}" -> el valor real de esa columna en `registro`; cualquier otra
  # cosa (texto literal entre las llaves, un typo) se deja intacta —
  # validar_campo_visualizacion/1 ya impide guardar una plantilla con
  # variables que no existen, esto es la segunda capa de defensa en tiempo
  # de lectura (fail-open, nunca rompe el picker por una config vieja).
  defp sustituir_variables(plantilla, registro) do
    Regex.replace(~r/\{(\w+)\}/, plantilla, fn original, campo ->
      valor_campo(registro, campo) || original
    end)
  end

  defp safe_atom(campo) do
    String.to_existing_atom(campo)
  rescue
    ArgumentError -> nil
  end

  defp etiqueta_opcion_referencia(registro, campos) when is_list(campos) and campos != [] do
    campos
    |> Enum.map(&Map.get(registro, String.to_existing_atom(&1)))
    |> Enum.reject(&(&1 in [nil, ""]))
    |> case do
      [] -> "##{registro.id}"
      valores -> Enum.map_join(valores, " · ", &to_string/1)
    end
  end

  defp etiqueta_opcion_referencia(registro, _campos), do: "##{registro.id}"

  defp resolver_acompanamiento(nil, _ids, _props), do: %{}
  defp resolver_acompanamiento(_modulo, [], _props), do: %{}

  # Trae la fila completa (no un `select: map(...)` acotado a
  # campos_acompanamiento) porque etiqueta_para_referencia/2 con
  # campo_visualizacion modo "calculado"/"plantilla" puede referenciar
  # cualquier campo del registro, no solo los de una lista fija conocida
  # de antemano.
  defp resolver_acompanamiento(modulo, ids, props) do
    from(t in modulo, where: t.id in ^ids)
    |> Repo.all()
    |> Map.new(&{&1.id, etiqueta_para_referencia(&1, props)})
  end

  defp agregar_acompanamiento(mapa, acompanamiento) when acompanamiento == %{}, do: mapa

  defp agregar_acompanamiento(mapa, acompanamiento) do
    Enum.reduce(acompanamiento, mapa, fn {campo, resueltos}, acc ->
      case Map.get(acc, campo) do
        nil -> acc
        id -> Map.put(acc, campo, Map.get(resueltos, id))
      end
    end)
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
