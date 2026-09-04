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
  alias MetadataApp.MetaStateEngine
  alias MetadataApp.Autenticacion
  alias MetadataApp.Autenticacion.Scope
  alias MetadataApp.Permissions
  alias MetadataApp.ParametrosCatalogo

  # Campos de control del CATALOGO_BASE ofrecibles como columnas
  # adicionales (2026-08-25) -- a diferencia de un campo de negocio
  # normal, no vienen de meta_schema_detail (id/estado/trn/branch/etc.
  # nunca tienen fila ahí, ver campos_del_catalogo/2 más abajo), así que
  # se marcan con "control" => true en vez de resolverse por catálogo.
  # Solo del catalogo_base a propósito (decisión 2026-08-25): las tablas
  # unidas (`joins`) no ofrecen esto todavía, para no multiplicar la
  # complejidad de "campo de control de CUÁL tabla" en la UI.
  # "empresa"/"creado_por" quedan afuera de este primer alcance (ambos
  # necesitan una resolución más cara -- empresa vía branch_id, creado_por
  # vía meta_schema_auditoria por el id crudo de la fila -- que no vale
  # la pena todavía sin un pedido concreto).
  @claves_control ~w(id estado trn branch inventory_location sales_unit)
  @etiquetas_control %{
    "id" => "ID",
    "estado" => "Estado",
    "trn" => "TRN",
    "branch" => "Sucursal",
    "inventory_location" => "Almacén",
    "sales_unit" => "Unidad de venta"
  }
  @campo_real_control %{
    "id" => :id,
    "estado" => :estado_id,
    "trn" => :trn,
    "branch" => :branch_id,
    "inventory_location" => :inventory_id,
    "sales_unit" => :sales_unit_id
  }

  @doc "Etiqueta legible de cada clave de control, para armar el checklist en el editor."
  def etiquetas_control, do: @etiquetas_control

  @doc """
  Claves de control ofrecibles para `catalogo_base` (para el checklist de
  Get Config) -- filtradas contra columnas reales del módulo compilado Y
  contra las mismas condiciones que ya usa un catálogo normal para
  decidir si "Estado"/"TRN"/Alcance tienen sentido ahí (ver
  CatalogoLive.montar_catalogo/2: estado necesita motor de estados
  adoptado, TRN necesita schema_es_transaccional, branch/inventory/sales
  necesitan alcance_habilitado). "id" siempre está disponible.
  """
  def claves_control_disponibles(catalogo_base) do
    header = MetaSchemaContext.obtener_header_por_nombre(catalogo_base)
    modulo = MetaSchemaContext.modulo_por_nombre(catalogo_base)
    campos_reales = modulo.__schema__(:fields)
    tiene_estados? = MetaStateEngine.mapa_nombres_estados(catalogo_base) != %{}

    Enum.filter(@claves_control, fn
      "id" -> true
      "estado" -> :estado_id in campos_reales and tiene_estados?
      "trn" -> header.schema_es_transaccional and :trn in campos_reales
      clave -> header.alcance_habilitado and Map.fetch!(@campo_real_control, clave) in campos_reales
    end)
  end

  @doc """
  Reemplaza los campos de control YA presentes (los del catalogo_base,
  marcados "control" => true) por `claves_seleccionadas` -- conserva
  etiqueta/orden/visible/totalizar de los que ya estaban, agrega los
  nuevos al final, saca los que se destildaron. Los campos de NEGOCIO
  (sin "control") no se tocan.
  """
  def sincronizar_campos_control(%Consulta{} = consulta, claves_seleccionadas) do
    base = consulta.catalogo_base
    existentes_por_clave = Map.new(Enum.filter(consulta.campos, &(&1["control"] == true)), &{&1["campo"], &1})
    sin_control = Enum.reject(consulta.campos, &(&1["control"] == true))
    offset = length(sin_control)

    nuevos_control =
      claves_seleccionadas
      |> Enum.with_index()
      |> Enum.map(fn {clave, indice} ->
        Map.get(existentes_por_clave, clave) ||
          %{
            "catalogo" => base,
            "campo" => clave,
            "control" => true,
            "etiqueta" => Map.fetch!(@etiquetas_control, clave),
            "tipo" => nil,
            "orden" => offset + indice,
            "visible" => true,
            "agregacion_activa" => false,
            "bloqueado" => false
          }
      end)

    actualizar_campos(consulta, sin_control ++ nuevos_control)
  end

  # SPEC-SYS-0209202601 (2026-09-02): el motor de "Parámetro" estándar
  # (tipos elegibles, tipo_efectivo/1, campos_elegibles_*/1,
  # aplicar_filtros_*_estandar) se mudó a `MetadataApp.ParametrosCatalogo`
  # -- ya no atado a `%Consulta{}`, lo comparte un catálogo (BC) normal.
  # Acá queda como adaptador fino: `consulta.campos` ya viene en el shape
  # que ese módulo espera, sin transformar nada.
  defdelegate tipo_efectivo(campo), to: ParametrosCatalogo
  defdelegate catalogo_control_sistema(clave), to: ParametrosCatalogo
  defdelegate tipo_elegible?(tipo), to: ParametrosCatalogo
  defdelegate clave_campo(campo), to: ParametrosCatalogo

  @doc """
  Campos VISIBLES, de tipo fecha Y marcados "es_parametro" => true por el
  admin en Get Config -- ver moduledoc de `MetaSchema.Consulta`.
  """
  def campos_elegibles_fecha(%Consulta{campos: campos}), do: ParametrosCatalogo.campos_elegibles_fecha(campos)

  @doc "Campos VISIBLES, de tipo string/referencia Y marcados \"es_parametro\" => true."
  def campos_elegibles_string(%Consulta{campos: campos}), do: ParametrosCatalogo.campos_elegibles_string(campos)

  @doc "Campos VISIBLES, de tipo integer/decimal Y marcados \"es_parametro\" => true."
  def campos_elegibles_numerico(%Consulta{campos: campos}), do: ParametrosCatalogo.campos_elegibles_numerico(campos)

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
        "agregacion_activa" => false,
        "bloqueado" => false
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
  "Orden de resultados" (R1, admin, 2026-08-27) — reemplaza `orden_por`
  entero, mismo criterio simple que `actualizar_campos/2` (la lista
  completa la arma el caller, acá solo persiste). Sin validar que cada
  entrada siga apuntando a un campo real de la consulta -- `aplicar_orden/3`
  ya ignora en silencio cualquier entrada que ya no calce (columna quitada
  después de agregarla al orden), no hace falta duplicar ese chequeo acá.
  """
  def actualizar_orden_por(%Consulta{} = consulta, orden_por) do
    consulta
    |> Consulta.changeset(%{"orden_por" => orden_por})
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

  @doc """
  Corrige la unión de una tabla YA agregada (mismo shape que
  `agregar_tabla_manual/5`, sin volver a agregarla) -- para cuando la
  unión quedó mal configurada (ej. bug real 2026-08-27: un join contra
  una tabla DETALLE de un maestro-detalle -- "encabezado_id"/"renglon_id",
  ver moduledoc de CatalogoGenerador -- se agregó a mano con
  campo_en_nuevo="id" en vez de "encabezado_id"; `detectar_union/2` solo
  reconoce campos "referencia" reales, nunca la relación estructural de
  maestro-detalle, así que ese caso siempre requiere `agregar_tabla_manual/5`
  y es fácil elegir mal). A diferencia de sacar y volver a agregar la
  tabla (`quitar_ultima_tabla/1` + `agregar_tabla_manual/5`), esto NO
  toca `campos` -- toda la config de Get Config ya hecha sobre esa tabla
  (etiquetas, Parámetro, Defaults) se conserva tal cual.
  """
  def corregir_union(%Consulta{} = consulta, catalogo, campo_en_nuevo, campo_en_destino) do
    joins =
      Enum.map(consulta.joins, fn join ->
        if join["catalogo"] == catalogo,
          do: Map.merge(join, %{"campo_en_nuevo" => campo_en_nuevo, "campo_en_destino" => campo_en_destino}),
          else: join
      end)

    consulta
    |> Consulta.changeset(%{"joins" => joins})
    |> Ecto.Changeset.change(%{update_guid: generar_guid()})
    |> Repo.update()
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
    via_maestro_detalle = detectar_union_maestro_detalle(catalogos_actuales, catalogo_nuevo)

    via_nuevo =
      catalogo_nuevo
      |> MetaSchemaContext.listar_detalles()
      |> Enum.find_value(fn detalle ->
        props = detalle.schema_context_properties || %{}

        if props["tipo"] == "referencia" and props["catalogo"] in catalogos_actuales do
          %{"catalogo_destino" => props["catalogo"], "campo_en_destino" => "id", "campo_en_nuevo" => detalle.schema_context_field}
        end
      end)

    case via_maestro_detalle || via_nuevo || detectar_union_desde_existentes(catalogos_actuales, catalogo_nuevo) do
      nil -> :sin_union
      union -> {:ok, union}
    end
  end

  # Maestro-detalle (R3) se detecta APARTE de "referencia" (arriba/abajo)
  # porque no es un campo "referencia" configurado en meta_schema_detail:
  # "encabezado_id" es una columna de framework que CatalogoGenerador
  # agrega sola a todo catálogo detalle (ver moduledoc de
  # CatalogoGenerador) — listar_detalles/1 nunca la ve, así que
  # detectar_union_desde_existentes/2 (que solo escanea "referencia") no
  # puede encontrarla. A diferencia de una "referencia" (varias
  # combinaciones legítimas de campo), acá la clave SIEMPRE es
  # encabezado_id → id: se puede autodetectar sin ambigüedad, con
  # prioridad sobre "referencia" (más específico, más confiable). Bug real
  # 2026-08-26/27 que motiva esto: un admin unió a mano un maestro con su
  # detalle por "id"="id" (la opción que ofrecía el editor manual antes de
  # este cambio) — traía 1 fila por maestro en vez del fan-out real (ver
  # corregir_union/4, que se usó para arreglarlo a mano en su momento).
  defp detectar_union_maestro_detalle(catalogos_actuales, catalogo_nuevo) do
    header_nuevo = MetaSchemaContext.obtener_header_por_nombre(catalogo_nuevo)

    via_nuevo_es_detalle =
      with %{schema_encabezado_id: id} when not is_nil(id) <- header_nuevo,
           maestro <- MetaSchemaContext.obtener_header!(id),
           true <- maestro.schema_context_name in catalogos_actuales do
        %{"catalogo_destino" => maestro.schema_context_name, "campo_en_destino" => "id", "campo_en_nuevo" => "encabezado_id"}
      else
        _ -> nil
      end

    via_nuevo_es_detalle ||
      (header_nuevo &&
         Enum.find_value(catalogos_actuales, fn tabla ->
           header_tabla = MetaSchemaContext.obtener_header_por_nombre(tabla)

           if header_tabla && header_tabla.schema_encabezado_id == header_nuevo.id do
             %{"catalogo_destino" => tabla, "campo_en_destino" => "encabezado_id", "campo_en_nuevo" => "id"}
           end
         end))
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
  Etiqueta del maestro si `catalogo` es detalle de alguno, `nil` si no.
  Pensado para que la UI (BcListLive) avise el fan-out de una tabla
  detalle ANTES/mientras se configura su unión, sin importar qué campo
  termine eligiéndose — la advertencia depende de la naturaleza
  estructural del catálogo, no de la unión ya armada (ver
  detectar_union_maestro_detalle/2 arriba). Bug real 2026-08-26 que
  motiva esto: agregar una tabla detalle sin ningún aviso sorprendió con
  "ahora salen 2 filas por cliente" recién al ver el reporte.
  """
  def maestro_de_detalle(catalogo) do
    with %{schema_encabezado_id: id} when not is_nil(id) <- MetaSchemaContext.obtener_header_por_nombre(catalogo),
         %{schema_context_label: etiqueta} <- MetaSchemaContext.obtener_header!(id) do
      etiqueta
    else
      _ -> nil
    end
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
  Nombres de campo utilizables como llave de unión para un catálogo: sus
  campos configurados en `meta_schema_detail` más `"id"` (que siempre
  existe pero nunca es un detail configurable, así que no aparece solo
  con `MetaSchemaContext.listar_detalles/1`) más `"encabezado_id"` cuando
  el catálogo es detalle de un maestro (columna de framework, tampoco
  aparece en `meta_schema_detail` — ver `detectar_union_maestro_detalle/2`
  arriba). Usado por el editor manual de uniones cuando `detectar_union/2`
  no encuentra nada — red de seguridad para que, si el admin tiene que
  elegir a mano, al menos tenga la opción correcta disponible.
  """
  def campos_disponibles_para_union(catalogo) do
    nombres = catalogo |> MetaSchemaContext.listar_detalles() |> Enum.map(& &1.schema_context_field)
    header = MetaSchemaContext.obtener_header_por_nombre(catalogo)
    extra_detalle = if header && header.schema_encabezado_id, do: ["encabezado_id"], else: []
    Enum.uniq(["id" | extra_detalle] ++ nombres)
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
  Query "representativa" de la consulta -- joins reales + `select` de las
  columnas visibles (Get Config), tal como las arma `ejecutar/6`, pero
  SIN filtros/alcance/paginación (esos dependen de cada request, no
  tiene sentido fijarlos en una query de referencia). Pensada para el
  tab SQL del admin (ver ConsultaEditorLive) -- nunca para ejecutar
  contra la base de verdad.
  """
  def query_representativa(%Consulta{} = consulta) do
    {base, alias_por_catalogo} = construir_query_base(consulta)
    visibles = campos_visibles_ordenados(consulta)
    select(base, ^select_dinamico(visibles, alias_por_catalogo))
  end

  @doc """
  Igual que `query_representativa/1`, pero además con los WHERE de
  Parámetro estándar YA aplicados (fecha/string/numérico, ver moduledoc
  de `MetaSchema.Consulta`) -- para que el admin vea la FORMA real del
  filtro que se va a generar en el tab SQL/Ecto, no solo los joins+select.
  Sigue sin alcance/paginación (dependen de la sesión de cada request,
  no tiene sentido fijarlos acá) y sigue sin ejecutarse nunca contra la
  base de verdad.

  Un campo elegible SIN default todavía configurado usa un valor dummy
  (ver `overrides_dummy/1`) solo para que el WHERE aparezca en el SQL de
  ejemplo -- nunca pisa un default REAL ya guardado, que siempre gana.
  """
  def query_representativa_con_filtros(%Consulta{} = consulta) do
    {base, alias_por_catalogo} = construir_query_base(consulta)
    visibles = campos_visibles_ordenados(consulta)

    base
    |> select(^select_dinamico(visibles, alias_por_catalogo))
    |> ParametrosCatalogo.aplicar_filtros_parametro_estandar(consulta.campos, alias_por_catalogo, overrides_dummy(consulta))
  end

  # Un valor placeholder POR CAMPO elegible que todavía no tiene default
  # real -- nunca pisa uno ya configurado (cada dummy_*/1 solo llena las
  # claves de "defaults" que vengan vacías, ver campo_efectivo/2).
  defp overrides_dummy(consulta) do
    fecha = Enum.map(campos_elegibles_fecha(consulta), &{to_string(clave_campo(&1)), dummy_fecha(&1)})
    string = Enum.map(campos_elegibles_string(consulta), &{to_string(clave_campo(&1)), dummy_string(&1)})
    numerico = Enum.map(campos_elegibles_numerico(consulta), &{to_string(clave_campo(&1)), dummy_numerico(&1)})
    Map.new(fecha ++ string ++ numerico)
  end

  defp dummy_fecha(campo) do
    if (campo["defaults"] || %{})["modo"] in [nil, ""] do
      %{"defaults" => %{"modo" => if(campo["acotado"], do: "mes_actual", else: "actual")}}
    else
      %{}
    end
  end

  defp dummy_string(campo) do
    defaults = campo["defaults"] || %{}

    cond do
      campo["tipo_filtro"] == "multi" and (defaults["valores"] || []) == [] ->
        %{"defaults" => %{"valores" => ["1"]}}

      campo["tipo_filtro"] != "multi" and defaults["valor"] in [nil, ""] ->
        valor = if tipo_efectivo(campo) == "referencia" or campo["origen"] == "referenciado", do: "1", else: "ejemplo"
        %{"defaults" => %{"valor" => valor}}

      true ->
        %{}
    end
  end

  defp dummy_numerico(campo) do
    defaults = campo["defaults"] || %{}

    if campo["acotado"] do
      valor = if defaults["valor"] in [nil, ""], do: 1, else: defaults["valor"]
      valor_hasta = if defaults["valor_hasta"] in [nil, ""], do: 100, else: defaults["valor_hasta"]
      if valor == defaults["valor"] and valor_hasta == defaults["valor_hasta"], do: %{}, else: %{"defaults" => %{"valor" => valor, "valor_hasta" => valor_hasta}}
    else
      if defaults["valor"] in [nil, ""], do: %{"defaults" => %{"valor" => 1}}, else: %{}
    end
  end

  @doc """
  Total de filas para los mismos filtros/búsqueda, sin paginar — para que
  CatalogoLive calcule `total_paginas` ANTES de pedir la página con el
  offset correcto, igual que ya hace para un catálogo normal.

  `scope` -- posicional, sin default, mismo criterio que
  `CatalogoGenerico.listar/contar` (elige a propósito no tener un default
  "seguro": un choke point de lectura no debe dejar que un caller se
  olvide el scope sin darse cuenta). Ver `aplicar_alcance_de_datos/4`.

  Cada campo elegible (ver moduledoc de `MetaSchema.Consulta`) aplica su
  propio default de Parámetro solo, leído directo de `consulta.campos`
  (ver `aplicar_filtros_fecha_estandar/4` y análogas) -- no hace falta
  que el caller calcule ni pase nada aparte, salvo que quiera pisar el
  default de ALGÚN campo puntual para este request (`overrides_parametro`,
  ver ahí).
  """
  def contar(%Consulta{} = consulta, scope, filtros \\ %{}, busqueda \\ nil, overrides_parametro \\ %{}) do
    {base, alias_por_catalogo} = construir_query_base(consulta)

    base
    |> aplicar_filtros(filtros, consulta.campos, alias_por_catalogo)
    |> aplicar_busqueda(busqueda, consulta.campos, alias_por_catalogo)
    |> ParametrosCatalogo.aplicar_filtros_parametro_estandar(consulta.campos, alias_por_catalogo, overrides_parametro)
    |> aplicar_alcance_de_datos(consulta, alias_por_catalogo, scope)
    |> Repo.aggregate(:count)
  end

  # SPEC-SYS-0209202601: el motor de "Parámetro" estándar (los tres tipos,
  # campo_efectivo/2, aplicar_filtro_estandar/4, aplicar_si_presente/5, el
  # aplicar_filtro/4 de bajo nivel) se mudó entero a
  # `MetadataApp.ParametrosCatalogo.aplicar_filtros_parametro_estandar/4`
  # -- acá solo quedan los call sites, ver `contar/5`/`ejecutar/6`/
  # `query_representativa_con_filtros/1`.

  @doc """
  `props` (shape `CatalogoGenerico.opciones_referencia/3`) para armar las
  opciones de un parámetro con origen "referenciado" (ver moduledoc de
  `MetaSchema.Consulta`) -- un campo YA tipo "referencia" resuelve su
  catálogo destino real de `meta_schema_detail` (mismo criterio que
  cualquier filtro "referencia" de siempre); un campo "string" genuino
  usa el catálogo que el admin eligió a mano (`campo["catalogo_referenciado"]`).
  Los 3 catálogos de sistema (branch/inventory_location/sales_unit) no
  tienen fila en `meta_schema_detail` de la que copiar
  "campos_acompanamiento" -- sin esto, `opciones_referencia/3` etiqueta
  cada opción "#<id>" en vez del nombre real, se resuelve acá de
  `MetaSchemaContext.catalogo_sistema/1`. `nil` si no se puede resolver
  nada (campo/catálogo raro, no debería pasar desde la UI).
  """
  defdelegate props_referenciado(campo, detalles_por_catalogo), to: ParametrosCatalogo

  # Alcance de Datos (mismo modelo que CatalogoGenerico.aplicar_alcance_de_datos/3,
  # ver ahí el moduledoc de Scope para el diseño completo) -- SOLO contra
  # `catalogo_base`, nunca contra las tablas de `joins` (decisión explícita:
  # una Consulta no tiene alcance propio, hereda el de la tabla que la
  # origina; acotar también los joins abriría preguntas sin respuesta clara
  # -- ¿alcance de CUÁL tabla manda si difieren? -- que no hacen falta para
  # el caso real de hoy). Misma firma/orden de cláusulas que
  # aplicar_filtro_fecha_default/4 de arriba: alcance_habilitado vive en el
  # Header de catalogo_base, nunca en el de la Consulta (esa no tiene
  # branch_id/sales_unit_id/etc. propios que filtrar).
  defp aplicar_alcance_de_datos(query, _consulta, _alias_por_catalogo, :sistema), do: query

  defp aplicar_alcance_de_datos(query, consulta, alias_por_catalogo, nil) do
    case MetaSchemaContext.obtener_header_por_nombre(consulta.catalogo_base) do
      %{alcance_habilitado: true} ->
        alias_tabla = Map.fetch!(alias_por_catalogo, consulta.catalogo_base)
        where(query, [{^alias_tabla, _r}], false)

      _ ->
        query
    end
  end

  defp aplicar_alcance_de_datos(query, consulta, alias_por_catalogo, %Scope{} = scope) do
    case MetaSchemaContext.obtener_header_por_nombre(consulta.catalogo_base) do
      %{alcance_habilitado: true} = header ->
        scope
        |> Permissions.alcance_tipo_efectivo(header.id)
        |> aplicar_where_de_alcance(query, scope, consulta.catalogo_base, alias_por_catalogo)

      _ ->
        query
    end
  end

  defp aplicar_where_de_alcance(:global, query, _scope, _catalogo, _alias_por_catalogo), do: query

  defp aplicar_where_de_alcance(:empresa, query, scope, catalogo, alias_por_catalogo) do
    con_columna_alcance(query, catalogo, alias_por_catalogo, :empresa_id, fn alias_tabla, campo ->
      where(query, [{^alias_tabla, r}], is_nil(field(r, ^campo)) or field(r, ^campo) == ^scope.empresa_activa.id)
    end)
  end

  defp aplicar_where_de_alcance(:branch, query, scope, catalogo, alias_por_catalogo) do
    con_columna_alcance(query, catalogo, alias_por_catalogo, :branch_id, fn alias_tabla, campo ->
      where(query, [{^alias_tabla, r}], is_nil(field(r, ^campo)) or field(r, ^campo) in ^scope.branches_permitidos)
    end)
  end

  defp aplicar_where_de_alcance(:sales_unit, query, scope, catalogo, alias_por_catalogo) do
    con_columna_alcance(query, catalogo, alias_por_catalogo, :sales_unit_id, fn alias_tabla, campo ->
      where(query, [{^alias_tabla, r}], is_nil(field(r, ^campo)) or field(r, ^campo) in ^scope.sales_units_permitidas)
    end)
  end

  defp aplicar_where_de_alcance(:inventory_location, query, scope, catalogo, alias_por_catalogo) do
    con_columna_alcance(query, catalogo, alias_por_catalogo, :inventory_id, fn alias_tabla, campo ->
      where(query, [{^alias_tabla, r}], is_nil(field(r, ^campo)) or field(r, ^campo) in ^scope.inventory_locations_permitidas)
    end)
  end

  defp aplicar_where_de_alcance(:propio, query, scope, catalogo, alias_por_catalogo) do
    con_columna_alcance(query, catalogo, alias_por_catalogo, :creado_por_id, fn alias_tabla, campo ->
      where(query, [{^alias_tabla, r}], is_nil(field(r, ^campo)) or field(r, ^campo) == ^scope.usuario.id)
    end)
  end

  # Igual de permisivo que con_columna/3 en CatalogoGenerico: si
  # catalogo_base no tiene la columna que ese alcance_tipo necesita, no
  # filtra nada (no-op) en vez de reventar.
  defp con_columna_alcance(query, catalogo, alias_por_catalogo, campo, construir_where) do
    schema_mod = MetaSchemaContext.modulo_por_nombre(catalogo)
    alias_tabla = Map.fetch!(alias_por_catalogo, catalogo)

    if campo in schema_mod.__schema__(:fields), do: construir_where.(alias_tabla, campo), else: query
  end

  @doc """
  Ejecuta la consulta y devuelve `%{filas:, total_filas:, totales:}`.
  `filtros`/`opciones`/`busqueda` — mismo shape exacto que
  `CatalogoGenerico.listar/4` + `contar/3`, para reusar el mismo popover
  de filtros de CatalogoLive sin ninguna adaptación (los nombres de
  campo siguen siendo los crudos, sin catálogo — ver nota en
  `aplicar_filtros/3` sobre el único caso raro que no cubre).

  `scope` -- ver `contar/5`. `overrides_parametro` -- ver
  `aplicar_filtros_parametro_estandar/4`.

  `totales` — suma de cada campo marcado `"agregacion_activa": true`
  (SPEC-SYS-0209202601 -- mismo shape rico que ya usaba un catálogo BC,
  antes un simple `"totalizar": true`), sobre TODAS las filas que
  matchean filtros/búsqueda/alcance (no solo la página actual). Las
  claves de `filas`/`totales` son las de `clave_campo/1`, no el nombre
  de campo crudo.
  """
  def ejecutar(%Consulta{} = consulta, scope, filtros \\ %{}, opciones \\ [], busqueda \\ nil, overrides_parametro \\ %{}) do
    {base, alias_por_catalogo} = construir_query_base(consulta)
    visibles = campos_visibles_ordenados(consulta)

    query =
      base
      |> aplicar_filtros(filtros, consulta.campos, alias_por_catalogo)
      |> aplicar_busqueda(busqueda, consulta.campos, alias_por_catalogo)
      |> ParametrosCatalogo.aplicar_filtros_parametro_estandar(consulta.campos, alias_por_catalogo, overrides_parametro)
      |> aplicar_alcance_de_datos(consulta, alias_por_catalogo, scope)

    total_filas = Repo.aggregate(query, :count)
    select_filas = select_dinamico(visibles, alias_por_catalogo)

    detalles_por_catalogo = MetaSchemaContext.listar_detalles_de_varios(catalogos_presentes(consulta))

    filas =
      query
      |> aplicar_orden(consulta, alias_por_catalogo)
      |> select(^select_filas)
      |> CatalogoGenerico.aplicar_paginacion(opciones)
      |> Repo.all()
      |> resolver_campos_control(visibles, consulta.catalogo_base)
      |> resolver_campos_referencia(visibles, detalles_por_catalogo)

    %{filas: filas, total_filas: total_filas, totales: totales(query, consulta, alias_por_catalogo)}
  end

  # "Orden de resultados" (R1, admin) -- aplicado SOLO a la query de
  # `filas` (nunca a `query` en sí, que también alimenta total_filas/
  # totales/3 más abajo -- un ORDER BY ahí es trabajo desperdiciado en el
  # mejor caso, o puede chocar con un SELECT agregado sin GROUP BY en el
  # peor, mismo motivo que el `exclude(:order_by)` de totales/3). Ecto
  # acumula (no reemplaza) llamadas sucesivas a order_by/3, así que cada
  # vuelta del reduce agrega una columna más de desempate, respetando la
  # prioridad de `orden_por`. Una entrada que ya no calza con ningún campo
  # real de la consulta (columna quitada después de agregarla al orden) se
  # ignora en silencio, nunca revienta la consulta.
  defp aplicar_orden(query, %Consulta{orden_por: orden_por, campos: campos}, alias_por_catalogo) do
    Enum.reduce(orden_por, query, fn %{"catalogo" => catalogo, "campo" => campo, "direccion" => direccion}, acc ->
      case Enum.find(campos, &(&1["catalogo"] == catalogo and &1["campo"] == campo)) do
        nil ->
          acc

        campo_def ->
          alias_tabla = Map.fetch!(alias_por_catalogo, catalogo)
          campo_atom = campo_atom_real(campo_def)
          direccion_atom = if direccion == "desc", do: :desc, else: :asc
          order_by(acc, [{^alias_tabla, t}], [{^direccion_atom, field(t, ^campo_atom)}])
      end
    end)
  end

  defp campos_visibles_ordenados(%Consulta{campos: campos}) do
    campos
    |> Enum.filter(&(Map.get(&1, "visible") == true))
    |> Enum.sort_by(&Map.get(&1, "orden", 0))
  end

  defp select_dinamico(campos, alias_por_catalogo) do
    Map.new(campos, fn campo ->
      alias_tabla = Map.fetch!(alias_por_catalogo, campo["catalogo"])
      campo_atom = campo_atom_real(campo)
      {clave_campo(campo), dynamic([{^alias_tabla, t}], field(t, ^campo_atom))}
    end)
  end

  # "id"/"trn" seleccionan directo, valen tal cual. "estado"/"branch"/
  # "inventory_location"/"sales_unit" seleccionan el id crudo real
  # (estado_id/branch_id/...) -- se resuelven a nombre legible recién
  # después del Repo.all/1, ver resolver_campos_control/3.
  defp campo_atom_real(%{"control" => true, "campo" => clave}), do: Map.fetch!(@campo_real_control, clave)
  defp campo_atom_real(%{"campo" => campo}), do: String.to_existing_atom(campo)

  @claves_control_a_resolver ~w(estado branch inventory_location sales_unit)

  # Batch por columna (una consulta por clave de control presente, nunca
  # una por fila) -- mismo espíritu que agregar_alcance_a_filas/2 y
  # mapa_nombres_estados/1 para un catálogo normal.
  defp resolver_campos_control(filas, campos_visibles, catalogo_base) do
    campos_visibles
    |> Enum.filter(&(&1["control"] == true and &1["campo"] in @claves_control_a_resolver))
    |> Enum.reduce(filas, fn campo, filas_acc ->
      clave = clave_campo(campo)
      resolver = resolver_control(campo["campo"], catalogo_base)
      Enum.map(filas_acc, &Map.update!(&1, clave, resolver))
    end)
  end

  defp resolver_control("estado", catalogo_base) do
    mapa = MetaStateEngine.mapa_nombres_estados(catalogo_base)
    fn id -> id && Map.get(mapa, id) end
  end

  defp resolver_control("branch", _catalogo_base) do
    fn id -> id && with(%{branch_name: nombre} <- Autenticacion.obtener_branch(id), do: nombre) end
  end

  defp resolver_control("inventory_location", _catalogo_base) do
    fn id -> id && with(%{inventory_name: nombre} <- Autenticacion.obtener_inventory_location(id), do: nombre) end
  end

  defp resolver_control("sales_unit", _catalogo_base) do
    fn id -> id && with(%{sales_unit_name: nombre} <- Autenticacion.obtener_sales_unit(id), do: nombre) end
  end

  # Un campo "tipo" => "referencia" normal (no de control -- esos ya
  # quedaron resueltos arriba) mostraba el id crudo de la FK en vez de su
  # etiqueta -- bug real 2026-08-27 (reporte "Clientes Core": columna
  # "U.Venta" mostraba "4"/"5" en vez de "Prev-Uriel"/"Prev-Jazmin", pese a
  # tener "campo_visualizacion" modo "descripcion" configurado -- la
  # misma etiqueta que CatalogoGenerico.etiqueta_para_referencia/2 ya usa
  # para un catálogo normal, acá nunca se llamaba). Batch por columna
  # (una query por relación por página, nunca una por fila) -- mismo
  # criterio que CatalogoGenerico.mapa_acompanamiento/2, reusando su
  # etiqueta_para_referencia/2 y modulo_destino_de/1 para no tener un
  # segundo mecanismo que se desincronice del primero.
  defp resolver_campos_referencia(filas, campos_visibles, detalles_por_catalogo) do
    campos_visibles
    |> Enum.filter(&(&1["control"] != true and &1["tipo"] == "referencia"))
    |> Enum.reduce(filas, fn campo, filas_acc ->
      clave = clave_campo(campo)
      props = props_referenciado(campo, detalles_por_catalogo)
      modulo = props && CatalogoGenerico.modulo_destino_de(props["catalogo"])

      ids = filas_acc |> Enum.map(&Map.get(&1, clave)) |> Enum.reject(&is_nil/1) |> Enum.uniq()
      etiquetas = resolver_etiquetas_referencia(modulo, ids, props)

      Enum.map(filas_acc, &Map.update!(&1, clave, fn id -> id && Map.get(etiquetas, id) end))
    end)
  end

  defp resolver_etiquetas_referencia(nil, _ids, _props), do: %{}
  defp resolver_etiquetas_referencia(_modulo, [], _props), do: %{}

  defp resolver_etiquetas_referencia(modulo, ids, props) do
    from(t in modulo, where: t.id in ^ids)
    |> Repo.all()
    |> Map.new(&{&1.id, CatalogoGenerico.etiqueta_para_referencia(&1, props)})
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

  # campo_atom_real/1 (no String.to_existing_atom/1 directo): un campo de
  # control "estado"/"branch"/"inventory_location"/"sales_unit" filtra
  # contra su columna real (estado_id/branch_id/...), nunca contra un
  # átomo literal con el nombre de la clave de control -- ese átomo no
  # es una columna real, filtrar/buscar con él reventaría en Postgres.
  defp resolver_campo(campos, alias_por_catalogo, campo_nombre) do
    case Enum.find(campos, &(&1["campo"] == to_string(campo_nombre))) do
      nil -> nil
      campo -> {Map.fetch!(alias_por_catalogo, campo["catalogo"]), campo_atom_real(campo)}
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

  # "mayor que"/"menor que" del Parámetro numérico estándar (ver moduledoc
  # de MetaSchema.Consulta) -- ESTRICTOS a propósito (`>`/`<`, no `>=`/
  # `<=`): "igual" ya cubre el caso de límite inclusivo, así que no hace
  # falta que "mayor" tape ese mismo caso.
  defp aplicar_filtro(query, alias_tabla, campo, {:mayor, valor}) do
    where(query, [{^alias_tabla, t}], field(t, ^campo) > ^valor)
  end

  defp aplicar_filtro(query, alias_tabla, campo, {:menor, valor}) do
    where(query, [{^alias_tabla, t}], field(t, ^campo) < ^valor)
  end

  defp aplicar_filtro(query, alias_tabla, campo, {:diferente, valor}) do
    where(query, [{^alias_tabla, t}], field(t, ^campo) != ^valor)
  end

  defp aplicar_filtro(query, _alias_tabla, _campo, {:entre, {nil, nil}}), do: query
  defp aplicar_filtro(query, alias_tabla, campo, {:entre, {desde, nil}}), do: aplicar_filtro(query, alias_tabla, campo, {:gte, desde})
  defp aplicar_filtro(query, alias_tabla, campo, {:entre, {nil, hasta}}), do: aplicar_filtro(query, alias_tabla, campo, {:lte, hasta})

  defp aplicar_filtro(query, alias_tabla, campo, {:entre, {desde, hasta}}) do
    where(query, [{^alias_tabla, t}], field(t, ^campo) >= ^desde and field(t, ^campo) <= ^hasta)
  end

  # Selección múltiple (parámetros tipo Sucursal/Almacén/Unidad de
  # venta/Producto, ver moduledoc de MetaSchema.Consulta) -- lista vacía
  # es "no elegiste nada todavía", no "no traigas nada": se ignora en vez
  # de armar un WHERE false, mismo criterio que un <select multiple>
  # nativo sin nada tildado.
  defp aplicar_filtro(query, _alias_tabla, _campo, {:in, []}), do: query

  defp aplicar_filtro(query, alias_tabla, campo, {:in, lista}) do
    where(query, [{^alias_tabla, t}], field(t, ^campo) in ^lista)
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
    campos_a_sumar = Enum.filter(campos, &(Map.get(&1, "agregacion_activa") == true))

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
  Igual que `CatalogoGenerico.agregar/6`, pero para una Consulta con JOIN
  — `campo_clave` es la clave namespaced (ver `clave_campo/1`, como
  string) porque acá puede haber más de una tabla y el campo crudo solo
  identifica la columna dentro de SU catálogo, no en toda la consulta.
  `funcion` es uno de :sum/:avg/:min/:max/:count. nil si `campo_clave` no
  existe en la consulta (defensivo — no debería pasar desde la UI).

  `overrides_parametro` (bug real 2026-09-04, mismo que
  `CatalogoGenerico.agregar/7`): faltaba acá desde que existe el
  parámetro de Fecha -- `contar/5`/`ejecutar/6` sí lo aplican
  (`ParametrosCatalogo.aplicar_filtros_parametro_estandar/4`), esta
  función seguía agregando sobre TODAS las filas de la consulta.
  """
  def agregar(%Consulta{} = consulta, campo_clave, funcion, filtros \\ %{}, busqueda \\ nil, overrides_parametro \\ %{}) do
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
        |> ParametrosCatalogo.aplicar_filtros_parametro_estandar(consulta.campos, alias_por_catalogo, overrides_parametro)
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
