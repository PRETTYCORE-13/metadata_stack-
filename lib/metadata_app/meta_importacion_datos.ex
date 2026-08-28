defmodule MetadataApp.MetaImportacionDatos do
  @moduledoc """
  Módulo de Importación de Datos — Fase 1 (catálogos simples) + Fase 2
  (maestro-detalle de 1 nivel, el que ya soporta la plataforma hoy; Fase 3
  extiende esto a N niveles reusando `MetaSchemaContext.arbol_detalle/1`).

  CRUD de `MetaSchema.PlantillaImportacion` — mismo patrón que
  `MetaPlantillas`/`Plantilla`, con una diferencia a propósito: acá NO hay
  "una activa por catálogo" (`publicar_plantilla/1` no tiene equivalente),
  varias plantillas pueden convivir activas (ej. "básica" y "completa" del
  mismo catálogo, ver `listar_activas/1`).

  El resto del módulo (generar/leer Excel, resolver referencias por clave
  de negocio, previsualizar/ejecutar) reusa el motor de validación real
  del catálogo — `CatalogoGenerico.crear/4`, INCLUIDO su soporte ya
  existente para crear encabezado + renglones de detalle atómicamente
  (`opciones[:renglones]`, ver `MetadataApp.Renglones.crear_todos/3`) — en
  vez de reimplementar ninguna regla. `previsualizar/3` y `ejecutar/3`
  corren exactamente el mismo código, la única diferencia es si la
  transacción de cada fila hace rollback a propósito (preview, nunca
  persiste) o commitea de verdad.

  Vínculo entre hojas (Fase 2): la plantilla define
  `"campo_identificador_encabezado"` (ej. "Folio") — cada hoja de detalle
  lleva esa misma columna como PRIMERA columna, y una fila de detalle se
  agrupa con la fila de encabezado cuyo valor de esa columna coincida. No
  existe hoy en la plataforma un concepto de "clave de negocio" fuera de
  este módulo — se sugiere (nunca se aplica a ciegas) desde el primer
  campo obligatorio de tipo texto del encabezado, ver
  `sugerir_campo_identificador/1`.
  """

  import Ecto.Query
  alias MetadataApp.Repo
  alias MetadataApp.MetaSchema.PlantillaImportacion
  alias MetadataApp.MetaErrores
  alias MetadataApp.BusinessProcessBuilder.{MetaSchemaContext, CatalogoGenerico}

  # =========================================================================
  # CRUD
  # =========================================================================

  def listar_plantillas(header_id) do
    from(p in PlantillaImportacion, where: p.meta_schema_header_id == ^header_id and is_nil(p.delete_guid), order_by: p.id)
    |> Repo.all()
  end

  @doc "Plantillas \"activa\" de un catálogo — usada por la barra de acciones de la Lista (CatalogoLive) para decidir si el botón \"Importar\" aparece."
  def listar_activas(header_id) do
    from(p in PlantillaImportacion,
      where: p.meta_schema_header_id == ^header_id and p.estado == "activa" and is_nil(p.delete_guid),
      order_by: p.nombre
    )
    |> Repo.all()
  end

  def obtener_plantilla!(id), do: Repo.get!(PlantillaImportacion, id)

  def crear_plantilla(header_id, attrs) do
    attrs = Map.merge(%{"meta_schema_header_id" => header_id}, attrs)

    %PlantillaImportacion{}
    |> PlantillaImportacion.changeset(attrs)
    |> Ecto.Changeset.change(%{insert_guid: generar_guid()})
    |> Repo.insert()
  end

  def actualizar_definicion(%PlantillaImportacion{} = plantilla, definicion) do
    plantilla
    |> PlantillaImportacion.changeset(%{"definicion" => definicion})
    |> Ecto.Changeset.change(%{update_guid: generar_guid()})
    |> Repo.update()
  end

  @doc "Nombre/descripción/definición juntos — un solo update, ver ImportacionConstructorLive.guardar_plantilla/2."
  def actualizar_plantilla(%PlantillaImportacion{} = plantilla, attrs) do
    plantilla
    |> PlantillaImportacion.changeset(attrs)
    |> Ecto.Changeset.change(%{update_guid: generar_guid()})
    |> Repo.update()
  end

  def activar(%PlantillaImportacion{} = plantilla), do: cambiar_estado(plantilla, "activa")
  def desactivar(%PlantillaImportacion{} = plantilla), do: cambiar_estado(plantilla, "borrador")

  defp cambiar_estado(plantilla, estado) do
    plantilla
    |> PlantillaImportacion.changeset(%{"estado" => estado})
    |> Ecto.Changeset.change(%{update_guid: generar_guid()})
    |> Repo.update()
  end

  def eliminar_plantilla(%PlantillaImportacion{} = plantilla) do
    plantilla
    |> Ecto.Changeset.change(%{delete_guid: generar_guid()})
    |> Repo.update()
  end

  # =========================================================================
  # Metadata de campos (asistente del BC + generación/lectura de Excel)
  # =========================================================================

  @doc "Campos visibles de `catalogo_nombre`, con etiqueta/tipo/ejemplo — la fuente de verdad del asistente \"Importación\" del BC para elegir qué columnas ofrecer (sirve tanto para el encabezado como para cada catálogo detalle)."
  def campos_disponibles(catalogo_nombre) do
    catalogo_nombre
    |> MetaSchemaContext.listar_detalles()
    |> Enum.filter(& &1.schema_context_properties["visible"])
    # "fecha_registro" es de CONTROL (el server lo pisa solo en cada alta,
    # mismo criterio que ya usa panel_campos/1 en bc_motor_live.ex) — nunca
    # tiene sentido pedírselo al usuario en una plantilla de importación.
    |> Enum.reject(&(&1.schema_context_field == "fecha_registro"))
    |> Enum.sort_by(& &1.schema_context_properties["orden"])
    |> Enum.map(fn d ->
      props = d.schema_context_properties

      %{
        campo: d.schema_context_field,
        etiqueta: props["etiqueta"] || d.schema_context_field,
        tipo: props["tipo"],
        catalogo_destino: props["catalogo"],
        obligatorio_default: props["opcional"] != true,
        ejemplo: valor_ejemplo(props)
      }
    end)
  end

  @doc "Catálogos detalle REALES de un maestro (Fase 2) — nombre/etiqueta, la lista que el paso \"¿Tiene detalles?\" del asistente ofrece tildar."
  def catalogos_detalle_disponibles(header_id) do
    header_id
    |> MetaSchemaContext.listar_catalogos_detalle()
    |> Enum.map(&%{catalogo: &1.schema_context_name, etiqueta: &1.schema_context_label})
  end

  defp valor_ejemplo(%{"tipo" => "referencia", "catalogo" => catalogo}), do: "(ver hoja/catálogo #{catalogo})"
  defp valor_ejemplo(%{"tipo" => "date"}), do: "31/12/2026"
  defp valor_ejemplo(%{"tipo" => "hora"}), do: "14:30"
  defp valor_ejemplo(%{"tipo" => "integer"}), do: "123"
  defp valor_ejemplo(%{"tipo" => "decimal"}), do: "123.45"
  defp valor_ejemplo(%{"tipo" => "enum", "valores" => [v | _]}) when is_binary(v), do: v
  defp valor_ejemplo(%{"tipo" => "enum", "valores" => [%{"valor" => v} | _]}), do: v
  defp valor_ejemplo(%{"tipo" => "enum"}), do: "opción"
  defp valor_ejemplo(_props), do: "Texto de ejemplo"

  @doc """
  Sugerencia (nunca una certeza — no existe hoy en la plataforma un
  concepto real de "clave de negocio", ver moduledoc) de qué campo sirve
  como identificador de un catálogo: el primer campo visible, obligatorio
  y de tipo texto (el caso más común — Folio, Código) o, si no hay ninguno
  así, el primer campo visible obligatorio de cualquier tipo. El asistente
  del BC siempre la muestra para confirmar/cambiar, nunca la aplica a
  ciegas.
  """
  def sugerir_campo_identificador(catalogo_nombre) do
    campos = campos_disponibles(catalogo_nombre)

    Enum.find_value(campos, fn c -> c.tipo == "string" and c.obligatorio_default and c.campo end) ||
      Enum.find_value(campos, fn c -> c.obligatorio_default and c.campo end)
  end

  # =========================================================================
  # Generación de Excel (Elixlsx) — encabezado + una hoja por detalle activo
  # =========================================================================

  @doc """
  Bytes del .xlsx descargable de `plantilla` — hoja de encabezado + una
  hoja por catálogo detalle activo, cada una con la columna identificadora
  primero. La fila de ejemplo usa un registro REAL (el más reciente) si el
  catálogo ya tiene datos — mucho más comprensible para el usuario final
  que un ejemplo sintético ("Texto de ejemplo", "123") — y cae a ese
  ejemplo sintético (`valor_ejemplo/1`) recién si el catálogo todavía está
  vacío. Encabezado y detalle usan el MISMO par de registros (el detalle
  se busca por `encabezado_id` del registro de encabezado elegido), así
  las hojas quedan coherentes entre sí — mismo Folio en todas.
  """
  def generar_excel(%PlantillaImportacion{} = plantilla) do
    header = MetaSchemaContext.obtener_header!(plantilla.meta_schema_header_id)
    campos_meta = campos_disponibles(header.schema_context_name) |> Map.new(&{&1.campo, &1})
    modulo = MetaSchemaContext.modulo_por_nombre(header.schema_context_name)
    registro_ejemplo = registro_mas_reciente(modulo)

    hoja_encabezado =
      construir_hoja(header.schema_context_label, plantilla.definicion["campos"] || [], campos_meta, nil, registro_ejemplo)

    detalles_activos = (plantilla.definicion["detalles"] || []) |> Enum.filter(& &1["activo"])
    identificador_campo = plantilla.definicion["campo_identificador_encabezado"]
    identificador_meta = campos_meta[identificador_campo]

    identificador_columna_extra =
      identificador_meta &&
        %{
          identificador_meta
          | ejemplo: valor_campo_ejemplo(%{"campo" => identificador_campo}, identificador_meta, registro_ejemplo)
        }

    hojas_detalle =
      Enum.map(detalles_activos, fn detalle_def ->
        detalle_header = MetaSchemaContext.obtener_header_por_nombre(detalle_def["catalogo"])
        detalle_campos_meta = campos_disponibles(detalle_def["catalogo"]) |> Map.new(&{&1.campo, &1})
        detalle_modulo = MetaSchemaContext.modulo_por_nombre(detalle_def["catalogo"])
        detalle_registro_ejemplo = registro_ejemplo && registro_de_detalle(detalle_modulo, registro_ejemplo.id)

        construir_hoja(
          detalle_header.schema_context_label,
          detalle_def["campos"] || [],
          detalle_campos_meta,
          identificador_columna_extra,
          detalle_registro_ejemplo
        )
      end)

    case Elixlsx.write_to_memory(%Elixlsx.Workbook{sheets: [hoja_encabezado | hojas_detalle]}, "plantilla.xlsx") do
      {:ok, {_nombre, binario}} -> {:ok, binario}
      {:error, motivo} -> {:error, motivo}
    end
  end

  defp registro_mas_reciente(nil), do: nil

  defp registro_mas_reciente(modulo) do
    Repo.one(from(r in modulo, where: is_nil(r.delete_guid), order_by: [desc: r.id], limit: 1))
  end

  defp registro_de_detalle(nil, _encabezado_id), do: nil

  defp registro_de_detalle(modulo, encabezado_id) do
    Repo.one(from(r in modulo, where: r.encabezado_id == ^encabezado_id and is_nil(r.delete_guid), order_by: [desc: r.id], limit: 1))
  end

  # Valor real de `campo_def` en `registro` (nil si no hay registro, o si
  # el campo vino vacío) traducido a algo mostrable en Excel — para
  # "referencia" resuelve al valor de negocio (nunca el id crudo, que es
  # justo lo que este módulo evita en todos lados, ver moduledoc). Cae al
  # ejemplo sintético de `meta.ejemplo` en cualquier caso sin dato real.
  defp valor_campo_ejemplo(_campo_def, meta, nil), do: meta.ejemplo

  defp valor_campo_ejemplo(campo_def, meta, registro) do
    campo_atom = String.to_existing_atom(campo_def["campo"])
    bruto = Map.get(registro, campo_atom)

    cond do
      bruto in [nil, ""] -> meta.ejemplo
      meta.tipo == "referencia" -> valor_referencia_legible(bruto, meta.catalogo_destino, campo_def["campo_identificador"]) || meta.ejemplo
      true -> formatear_valor_crudo(bruto)
    end
  end

  defp valor_referencia_legible(_id, _catalogo, campo_identificador) when campo_identificador in [nil, ""], do: nil

  defp valor_referencia_legible(id, catalogo, campo_identificador) do
    modulo = MetaSchemaContext.modulo_por_nombre(catalogo)
    Code.ensure_loaded(modulo)
    campo_atom = String.to_existing_atom(campo_identificador)

    case Repo.get(modulo, id) do
      nil -> nil
      registro -> Map.get(registro, campo_atom)
    end
  end

  defp formatear_valor_crudo(%Decimal{} = v), do: Decimal.to_float(v)
  defp formatear_valor_crudo(%Date{} = v), do: Calendar.strftime(v, "%d/%m/%Y")
  defp formatear_valor_crudo(%Time{} = v), do: Calendar.strftime(v, "%H:%M")
  defp formatear_valor_crudo(true), do: "true"
  defp formatear_valor_crudo(false), do: "false"
  defp formatear_valor_crudo(v) when is_binary(v) or is_number(v), do: v
  defp formatear_valor_crudo(v), do: to_string(v)

  # `columna_extra` (solo en hojas de detalle): el campo identificador del
  # encabezado va SIEMPRE primero — es la columna que vincula esta hoja
  # con su fila de encabezado, nunca un id interno. `registro_ejemplo`
  # (nil si el catálogo está vacío) es de dónde sale la fila de ejemplo
  # real en vez de la sintética, ver valor_campo_ejemplo/3.
  defp construir_hoja(nombre_hoja, campos_def, campos_meta, columna_extra, registro_ejemplo) do
    campos_ordenados = Enum.sort_by(campos_def, & &1["orden"])
    etiquetas_campos = Enum.map(campos_ordenados, &campos_meta[&1["campo"]].etiqueta)
    ejemplos_campos = Enum.map(campos_ordenados, &valor_campo_ejemplo(&1, campos_meta[&1["campo"]], registro_ejemplo))

    {etiquetas, ejemplos} =
      case columna_extra do
        nil -> {etiquetas_campos, ejemplos_campos}
        %{} = extra -> {[extra.etiqueta | etiquetas_campos], [extra.ejemplo | ejemplos_campos]}
      end

    %Elixlsx.Sheet{
      name: String.slice(nombre_hoja, 0, 31),
      rows: [
        Enum.map(etiquetas, &[&1, bold: true, bg_color: "#DDD9C4"]),
        # Bug real reportado: con un registro REAL como ejemplo (ver
        # valor_campo_ejemplo/3), la fila 2 se veía indistinguible de un
        # dato de verdad y el usuario la dejaba tal cual esperando que
        # se importara -- interpretar_filas/1 SIEMPRE la descarta, los
        # datos reales tienen que ir desde la fila 3. Cursiva + gris acá
        # para que se lea como "esto es solo un ejemplo", no un dato
        # cargado.
        Enum.map(ejemplos, &[&1, italic: true, color: "#9CA3AF"])
      ],
      pane_freeze: {1, 0}
    }
  end

  # =========================================================================
  # Lectura de Excel (Xlsxir) — encabezado (hoja 0) + una hoja por detalle
  # activo, en el MISMO orden en que generar_excel/1 las escribió.
  # =========================================================================

  @doc """
  Lee el archivo subido — `{:ok, %{"encabezado" => filas, "detalles" =>
  %{"catalogo" => filas, ...}}}` (cada fila un mapa `%{"Etiqueta" =>
  valor}`) o `{:error, motivo}`. Necesita `plantilla` para saber cuántas
  hojas de detalle esperar y en qué catálogo cae cada una.
  """
  def leer_excel(ruta_archivo, %PlantillaImportacion{} = plantilla) do
    detalles_activos = (plantilla.definicion["detalles"] || []) |> Enum.filter(& &1["activo"])

    with {:ok, filas_encabezado} <- leer_hoja(ruta_archivo, 0),
         {:ok, filas_por_detalle} <- leer_hojas_detalle(ruta_archivo, detalles_activos) do
      {:ok, %{"encabezado" => filas_encabezado, "detalles" => filas_por_detalle}}
    end
  end

  defp leer_hojas_detalle(ruta_archivo, detalles_activos) do
    detalles_activos
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, %{}}, fn {detalle_def, indice_hoja}, {:ok, acc} ->
      case leer_hoja(ruta_archivo, indice_hoja) do
        {:ok, filas} -> {:cont, {:ok, Map.put(acc, detalle_def["catalogo"], filas)}}
        {:error, motivo} -> {:halt, {:error, motivo}}
      end
    end)
  end

  defp leer_hoja(ruta_archivo, indice) do
    case Xlsxir.extract(ruta_archivo, indice) do
      {:ok, tid} ->
        filas_crudas = Xlsxir.get_list(tid)
        Xlsxir.close(tid)
        interpretar_filas(filas_crudas)

      {:error, motivo} ->
        {:error, motivo}
    end
  end

  defp interpretar_filas([]), do: {:error, "El archivo está vacío."}
  defp interpretar_filas([_solo_etiquetas]), do: {:ok, []}
  defp interpretar_filas([_etiquetas, _ejemplo]), do: {:ok, []}

  defp interpretar_filas([etiquetas, _ejemplo | filas]) do
    n = length(etiquetas)

    datos =
      filas
      |> Enum.map(&normalizar_valores/1)
      |> Enum.reject(&Enum.all?(&1, fn v -> v in [nil, ""] end))
      |> Enum.map(fn fila ->
        fila
        |> Kernel.++(List.duplicate(nil, n))
        |> Enum.take(n)
        |> then(&Enum.zip(etiquetas, &1))
        |> Map.new()
      end)

    {:ok, datos}
  end

  # Xlsxir devuelve una fecha como {anio, mes, dia} — se normaliza a Date
  # acá, un solo lugar, en vez de que cada campo tipo "date" tenga que
  # saber sobre el detalle de implementación de la librería lectora.
  defp normalizar_valores(fila), do: Enum.map(fila, &normalizar_celda/1)
  defp normalizar_celda({anio, mes, dia}), do: Date.new!(anio, mes, dia)
  defp normalizar_celda(valor), do: valor

  # =========================================================================
  # Resolución de referencias por clave de negocio (no existe en la
  # plataforma fuera de este módulo — ver moduledoc)
  # =========================================================================

  defp resolver_referencia(catalogo_destino, campo_identificador, valor) do
    modulo = MetaSchemaContext.modulo_por_nombre(catalogo_destino)
    Code.ensure_loaded(modulo)
    campo_atom = String.to_existing_atom(campo_identificador)

    query = from(r in modulo, where: field(r, ^campo_atom) == ^valor and is_nil(r.delete_guid), select: r.id)

    case Repo.all(query) do
      [id] -> {:ok, id}
      [] -> {:error, :no_encontrado}
      _ -> {:error, :ambiguo}
    end
  end

  # =========================================================================
  # Previsualización (dry-run) y ejecución real
  # =========================================================================

  @doc "Dry-run: corre cada fila de encabezado (con sus renglones de detalle agrupados) por el motor de validación real SIN persistir nada (rollback a propósito) — mismo resultado que `ejecutar/3` reportaría."
  def previsualizar(%PlantillaImportacion{} = plantilla, scope, filas) do
    procesar_filas(plantilla, scope, filas, false)
  end

  @doc "Igual que `previsualizar/3` pero persiste — un encabezado + sus renglones es UNA unidad atómica (mismo mecanismo que ya usa el alta manual, `opciones[:renglones]` de `CatalogoGenerico.crear/4`): si algún renglón falla, esa fila de encabezado entera se rechaza, pero no aborta las demás filas de encabezado — \"crear únicamente los registros válidos\"."
  def ejecutar(%PlantillaImportacion{} = plantilla, scope, filas) do
    procesar_filas(plantilla, scope, filas, true)
  end

  defp procesar_filas(plantilla, scope, %{"encabezado" => filas_encabezado} = filas, commit?) do
    filas_por_detalle_catalogo = Map.get(filas, "detalles", %{})
    header = MetaSchemaContext.obtener_header!(plantilla.meta_schema_header_id)
    modulo = MetaSchemaContext.modulo_por_nombre(header.schema_context_name)
    campos_meta = campos_disponibles(header.schema_context_name) |> Map.new(&{&1.campo, &1})

    identificador_campo = plantilla.definicion["campo_identificador_encabezado"]
    identificador_etiqueta = identificador_campo && get_in(campos_meta, [identificador_campo, :etiqueta])

    detalles_meta =
      (plantilla.definicion["detalles"] || [])
      |> Enum.filter(& &1["activo"])
      |> Map.new(fn detalle_def -> {detalle_def["catalogo"], {detalle_def, campos_disponibles(detalle_def["catalogo"]) |> Map.new(&{&1.campo, &1})}} end)

    filas_encabezado
    |> Enum.with_index(1)
    |> Enum.map(fn {fila_valores, indice} ->
      valor_identificador = identificador_etiqueta && Map.get(fila_valores, identificador_etiqueta)

      case construir_renglones_spec(detalles_meta, filas_por_detalle_catalogo, identificador_etiqueta, valor_identificador) do
        {:error, motivo} ->
          %{
            fila: indice,
            resultado: :error,
            errores: [%{campo: nil, etiqueta: identificador_etiqueta, valor: valor_identificador, mensaje: motivo, sugerencia: sugerencia_para(motivo)}]
          }

        {:ok, renglones_spec} ->
          procesar_fila(modulo, scope, campos_meta, plantilla, indice, fila_valores, renglones_spec, commit?)
      end
    end)
  end

  defp construir_renglones_spec(detalles_meta, _filas_por_detalle, _identificador_etiqueta, _valor_identificador) when map_size(detalles_meta) == 0,
    do: {:ok, %{}}

  defp construir_renglones_spec(detalles_meta, filas_por_detalle, identificador_etiqueta, valor_identificador) do
    Enum.reduce_while(detalles_meta, {:ok, %{}}, fn {catalogo, {detalle_def, detalle_campos_meta}}, {:ok, acc} ->
      filas_coincidentes =
        filas_por_detalle
        |> Map.get(catalogo, [])
        |> Enum.filter(&(Map.get(&1, identificador_etiqueta) == valor_identificador))

      case construir_attrs_lista(detalle_def["campos"] || [], detalle_campos_meta, filas_coincidentes) do
        {:ok, attrs_lista} -> {:cont, {:ok, Map.put(acc, catalogo, attrs_lista)}}
        {:error, motivo} -> {:halt, {:error, "#{catalogo}: #{motivo}"}}
      end
    end)
  end

  defp construir_attrs_lista(campos_def, campos_meta, filas) do
    Enum.reduce_while(filas, {:ok, []}, fn fila_valores, {:ok, acc} ->
      case construir_attrs(campos_def, campos_meta, fila_valores) do
        {:ok, attrs} -> {:cont, {:ok, [attrs | acc]}}
        {:error, {campo, motivo}} -> {:halt, {:error, "#{Map.get(campos_meta, campo, %{etiqueta: campo}).etiqueta}: #{motivo}"}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  defp procesar_fila(modulo, scope, campos_meta, plantilla, indice, fila_valores, renglones_spec, commit?) do
    case construir_attrs(plantilla.definicion["campos"] || [], campos_meta, fila_valores) do
      {:error, {campo, motivo}} ->
        etiqueta = get_in(campos_meta, [campo, :etiqueta]) || campo

        %{
          fila: indice,
          resultado: :error,
          errores: [
            %{campo: campo, etiqueta: etiqueta, valor: Map.get(fila_valores, etiqueta), mensaje: motivo, sugerencia: sugerencia_para(motivo)}
          ]
        }

      {:ok, attrs} ->
        Repo.transaction(fn ->
          case CatalogoGenerico.crear(modulo, scope, attrs, renglones: renglones_spec) do
            {:ok, registro} -> if commit?, do: registro, else: Repo.rollback({:preview_ok, registro})
            {:error, motivo} -> Repo.rollback({:error, motivo})
          end
        end)
        |> interpretar_resultado(indice, fila_valores, campos_meta)
    end
  end

  defp interpretar_resultado({:ok, registro}, indice, _fila_valores, _campos_meta),
    do: %{fila: indice, resultado: :ok, registro: registro}

  defp interpretar_resultado({:error, {:preview_ok, registro}}, indice, _fila_valores, _campos_meta),
    do: %{fila: indice, resultado: :ok, registro: registro}

  defp interpretar_resultado({:error, {:error, motivo}}, indice, fila_valores, campos_meta),
    do: %{fila: indice, resultado: :error, errores: errores_de(motivo, fila_valores, campos_meta)}

  defp errores_de(%Ecto.Changeset{} = changeset, fila_valores, campos_meta) do
    etiquetas = Map.new(campos_meta, fn {campo, meta} -> {to_string(campo), meta.etiqueta} end)

    changeset
    |> MetaErrores.traducir()
    |> Enum.map(fn {campo_atom, mensajes} ->
      campo = to_string(campo_atom)
      etiqueta = Map.get(etiquetas, campo, campo)
      mensaje = Enum.join(mensajes, "; ")
      %{campo: campo, etiqueta: etiqueta, valor: Map.get(fila_valores, etiqueta), mensaje: mensaje, sugerencia: sugerencia_para(mensaje)}
    end)
  end

  defp errores_de(motivo, _fila_valores, _campos_meta) do
    mensaje = mensaje_de_motivo(motivo)
    [%{campo: nil, etiqueta: nil, valor: nil, mensaje: mensaje, sugerencia: sugerencia_para(mensaje)}]
  end

  # `CatalogoGenerico.crear/4` devuelve `{:error, term()}` — no siempre un
  # Ecto.Changeset (ver clausula de arriba). Estos son los mismos términos
  # que ya traducen FichaLive.formatear_error/1 y FallbackController, para
  # cuando el catálogo exige alcance de datos activo (branch/sales_unit/
  # inventory) y quien importa no tiene uno elegido. `to_string/1` no
  # soporta tuplas (crasheaba acá), de ahí el catch-all con `inspect/1`.
  defp mensaje_de_motivo({:alcance_requerido, "branch_id"}),
    do: "No hay una Sucursal activa — elegí una desde la banda de pie antes de importar."

  defp mensaje_de_motivo({:alcance_requerido, "sales_unit_id"}),
    do: "No hay una Unidad de Venta activa — elegí una desde la banda de pie antes de importar."

  defp mensaje_de_motivo({:alcance_requerido, "inventory_id"}),
    do: "No hay un Almacén activo — elegí uno desde la banda de pie antes de importar."

  defp mensaje_de_motivo(motivo) when is_binary(motivo) or is_atom(motivo), do: to_string(motivo)
  defp mensaje_de_motivo(motivo), do: inspect(motivo)

  # Construye attrs a partir de UNA fila (encabezado o un renglón de
  # detalle — mismo mecanismo, distinta lista de campos/meta) SOLO con
  # los campos que la plantilla expone (ver moduledoc — un campo real
  # obligatorio que la plantilla no incluyó lo rechaza el motor de
  # siempre, gratis, no hace falta duplicar ese chequeo acá).
  defp construir_attrs(campos_def, campos_meta, fila_valores) do
    campos_def
    |> Enum.reduce_while({:ok, %{}}, fn campo_def, {:ok, attrs} ->
      campo = campo_def["campo"]
      campo_meta = Map.get(campos_meta, campo)
      valor_bruto = campo_meta && Map.get(fila_valores, campo_meta.etiqueta)

      case resolver_valor(campo_meta, campo_def, valor_bruto) do
        {:ok, valor} -> {:cont, {:ok, Map.put(attrs, campo, valor)}}
        {:error, motivo} -> {:halt, {:error, {campo, motivo}}}
      end
    end)
  end

  defp resolver_valor(nil, _campo_def, _valor), do: {:ok, nil}
  defp resolver_valor(_campo_meta, _campo_def, nil), do: {:ok, nil}
  defp resolver_valor(_campo_meta, _campo_def, ""), do: {:ok, nil}

  defp resolver_valor(%{tipo: "referencia", catalogo_destino: catalogo}, campo_def, valor) do
    case resolver_referencia(catalogo, campo_def["campo_identificador"], to_string(valor)) do
      {:ok, id} -> {:ok, id}
      {:error, :no_encontrado} -> {:error, "no se encontró ningún registro de \"#{catalogo}\" con ese valor"}
      {:error, :ambiguo} -> {:error, "hay más de un registro de \"#{catalogo}\" con ese valor — no se puede resolver sin ambigüedad"}
    end
  end

  # Una celda con fecha/hora REAL (formato de fecha en Excel) ya llegó
  # convertida a %Date{}/%Time{} por normalizar_celda/1 más arriba. Pero si
  # el usuario la escribió como texto plano (el caso más común al llenar
  # la plantilla a mano, con el MISMO formato dd/mm/aaaa y hh:mm que ya
  # usa el resto de la app para mostrar fechas/horas — ver
  # formatear_valor_crudo/1 y valor_ejemplo/1 acá mismo) Xlsxir la entrega
  # como string, y sin esto Ecto la rechazaba con "is invalid" porque
  # espera ISO8601 (aaaa-mm-dd) por default.
  defp resolver_valor(%{tipo: "date"}, _campo_def, %Date{} = valor), do: {:ok, valor}

  defp resolver_valor(%{tipo: "date"}, _campo_def, valor) when is_binary(valor) do
    case parsear_fecha_dd_mm_aaaa(valor) do
      {:ok, fecha} -> {:ok, fecha}
      :error -> {:error, "fecha inválida — se espera el formato dd/mm/aaaa"}
    end
  end

  defp resolver_valor(%{tipo: "hora"}, _campo_def, %Time{} = valor), do: {:ok, valor}

  defp resolver_valor(%{tipo: "hora"}, _campo_def, valor) when is_binary(valor) do
    case parsear_hora_hh_mm(valor) do
      {:ok, hora} -> {:ok, hora}
      :error -> {:error, "hora inválida — se espera el formato hh:mm"}
    end
  end

  defp resolver_valor(_campo_meta, _campo_def, valor), do: {:ok, valor}

  defp parsear_fecha_dd_mm_aaaa(valor) do
    with [dia, mes, anio] <- String.split(String.trim(valor), "/"),
         {dia, ""} <- Integer.parse(dia),
         {mes, ""} <- Integer.parse(mes),
         {anio, ""} <- Integer.parse(anio),
         {:ok, fecha} <- Date.new(anio, mes, dia) do
      {:ok, fecha}
    else
      _ -> :error
    end
  end

  defp parsear_hora_hh_mm(valor) do
    case String.split(String.trim(valor), ":") do
      [hora, minuto] -> construir_hora(hora, minuto, "0")
      [hora, minuto, segundo] -> construir_hora(hora, minuto, segundo)
      _ -> :error
    end
  end

  defp construir_hora(hora, minuto, segundo) do
    with {hora, ""} <- Integer.parse(hora),
         {minuto, ""} <- Integer.parse(minuto),
         {segundo, ""} <- Integer.parse(segundo),
         {:ok, hora_t} <- Time.new(hora, minuto, segundo) do
      {:ok, hora_t}
    else
      _ -> :error
    end
  end

  defp sugerencia_para(mensaje) do
    cond do
      mensaje =~ "blank" or mensaje =~ "vacío" -> "Completá este campo — es obligatorio."
      mensaje =~ "taken" or mensaje =~ "ya existe" or mensaje =~ "único" -> "Ya existe un registro con este valor — tiene que ser único."
      mensaje =~ "no se encontró" -> "Revisá que el valor exista en el catálogo relacionado, escrito exactamente igual."
      mensaje =~ "más de un" -> "El valor no identifica un único registro — hace falta un dato más específico."
      mensaje =~ "invalid" or mensaje =~ "inválido" or mensaje =~ "formato" -> "El formato no es válido — revisá el tipo de dato esperado."
      mensaje =~ "sin_scope" -> "No se pudo determinar la empresa/sucursal — iniciá sesión de nuevo e intentá otra vez."
      mensaje =~ "no permite insertar renglones" -> "El estado actual del catálogo no permite cargar detalles — revisá los permisos por estado en el Motor."
      true -> "Revisá el valor e intentá de nuevo."
    end
  end

  defp generar_guid, do: Ecto.UUID.generate() |> String.replace("-", "")
end
