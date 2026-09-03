defmodule MetadataApp.ParametrosCatalogo do
  @moduledoc """
  SPEC-SYS-0209202601 — motor de "Parámetro" estándar (filtro con widget
  real para el usuario final), extraído de `MetadataApp.MetaConsultas`
  para que lo comparta tanto una Consulta Ecto como un catálogo (BC)
  normal. Antes vivía atado a `%MetadataApp.MetaSchema.Consulta{}`; acá
  opera sobre `campos :: [map()]` (lista de mapas planos, mismo shape que
  ya usaba `consulta.campos` — ver moduledoc de `MetaSchema.Consulta`) y
  `alias_por_catalogo :: %{String.t() => atom()}` (mapa catálogo →
  binding nombrado de Ecto, `[as: ^alias]`) — ningún struct de origen
  específico.

  Para un catálogo (BC) de una sola tabla, `alias_por_catalogo` es
  simplemente `%{schema_context_name => :t0}` sobre una query armada con
  `from(r in modulo, as: :t0, ...)` — mismo mecanismo que ya usa
  `MetaConsultas.construir_query_base/1` para N tablas, con N = 1.

  `MetaConsultas` sigue siendo el dueño de `%Consulta{}` — pasa a ser un
  adaptador fino que llama acá.
  """

  import Ecto.Query

  alias MetadataApp.FiltrosDefault
  alias MetadataApp.BusinessProcessBuilder.MetaSchemaContext

  # Tipos elegibles para "Parámetro" estándar -- boolean/enum quedan
  # afuera a propósito. Elegible por TIPO no alcanza para ser parámetro:
  # hace falta además que el admin lo marque explícito con
  # "es_parametro" => true.
  @tipos_elegibles_fecha ~w(date)
  @tipos_elegibles_string ~w(string referencia)
  @tipos_elegibles_numerico ~w(integer decimal)

  # Campos de CONTROL de un catalogo_base de Consulta (id/estado/trn/
  # branch/inventory_location/sales_unit, ver MetaConsultas.claves_control_disponibles/1)
  # -- branch/inventory_location/sales_unit son conceptualmente una
  # referencia aunque su "tipo" guardado sea nil (no vienen de
  # meta_schema_detail). Un catálogo (BC) normal nunca alimenta acá un
  # campo con "control" => true (su grilla de Parámetro solo cubre
  # campos de negocio, ver design.md §1.4) -- estas cláusulas quedan
  # inertes para ese origen, no hace falta separarlas por origen.
  @controles_referencia ~w(branch inventory_location sales_unit)
  @catalogo_control_sistema %{
    "branch" => "meta_schema_branch",
    "inventory_location" => "meta_schema_inventory_location",
    "sales_unit" => "meta_schema_sales_unit"
  }
  @campo_real_control %{
    "id" => :id,
    "estado" => :estado_id,
    "trn" => :trn,
    "branch" => :branch_id,
    "inventory_location" => :inventory_id,
    "sales_unit" => :sales_unit_id
  }

  @doc """
  Tipo REAL a efectos de elegibilidad/UI de Parámetro estándar -- igual a
  `campo["tipo"]` salvo para los campos de control que son
  conceptualmente una referencia, donde siempre se resuelve a
  "referencia" aunque el campo tenga `"tipo" => nil` guardado.
  """
  def tipo_efectivo(%{"control" => true, "campo" => clave}) when clave in @controles_referencia, do: "referencia"
  def tipo_efectivo(campo), do: campo["tipo"]

  @doc "Catálogo de sistema real de un campo de control branch/inventory_location/sales_unit -- nil para cualquier otra clave."
  def catalogo_control_sistema(clave), do: Map.get(@catalogo_control_sistema, clave)

  @doc "true si el tipo de campo es elegible para Parámetro estándar (cualquiera de los tres grupos)."
  def tipo_elegible?(tipo), do: tipo in @tipos_elegibles_fecha ++ @tipos_elegibles_string ++ @tipos_elegibles_numerico

  @doc "Campos VISIBLES, de tipo fecha Y marcados \"es_parametro\" => true por el admin en Get Config."
  def campos_elegibles_fecha(campos), do: Enum.filter(campos, &campo_parametro?(&1, @tipos_elegibles_fecha))

  @doc "Campos VISIBLES, de tipo string/referencia Y marcados \"es_parametro\" => true."
  def campos_elegibles_string(campos), do: Enum.filter(campos, &campo_parametro?(&1, @tipos_elegibles_string))

  @doc "Campos VISIBLES, de tipo integer/decimal Y marcados \"es_parametro\" => true."
  def campos_elegibles_numerico(campos), do: Enum.filter(campos, &campo_parametro?(&1, @tipos_elegibles_numerico))

  defp campo_parametro?(campo, tipos), do: campo["visible"] == true and tipo_efectivo(campo) in tipos and campo["es_parametro"] == true

  @doc """
  Clave bajo la que aparece un campo en `filas`/`totales` — namespaced
  con el catálogo dueño para que dos tablas con un campo del mismo
  nombre (ej. ambas con "nombre") nunca choquen en el mapa resultado.
  Para un catálogo (BC) de una sola tabla, `catalogo` es siempre el
  mismo (su propio `schema_context_name`) — sigue sin ambigüedad, solo
  redundante. Con `String.to_atom/1` (no `to_existing_atom`) porque es
  un átomo compuesto que nunca existió antes — seguro acá porque
  "catalogo"/"campo" siempre vienen de catálogos ya dados de alta por
  un admin (universo acotado), nunca de texto libre de un usuario final.
  """
  def clave_campo(%{"catalogo" => catalogo, "campo" => campo}), do: String.to_atom("#{catalogo}__#{campo}")

  @doc "Átomo de columna física real para un campo (de control o de negocio) -- MetaConsultas también lo usa fuera del motor de Parámetro (select_dinamico/totales/resolver_campo), por eso es público."
  def campo_atom_real(%{"control" => true, "campo" => clave}), do: Map.fetch!(@campo_real_control, clave)
  def campo_atom_real(%{"campo" => campo}), do: String.to_existing_atom(campo)

  @doc """
  Los tres tipos de Parámetro estándar aplicados juntos, en orden
  (fecha, string, numérico) -- se resuelven directo contra SU
  catalogo+campo (`alias_por_catalogo`), nunca vía un mapa `filtros`
  genérico por nombre crudo (ambiguo si dos tablas unidas repiten
  nombre de columna).

  `overrides_parametro` -- `%{clave_campo_string => %{...}}` (ver
  `clave_campo/1`, mismo shape que el "defaults"/"acotado"/"tipo_filtro"
  de ese campo) -- para cuando el USUARIO FINAL cambia un parámetro
  desde el panel de filtros rápidos, sin pisar el default que configuró
  el admin en Get Config: vive SOLO en el socket de esa sesión (nunca se
  persiste acá), `%{}` es "usar el default de todos los campos tal cual
  están guardados".
  """
  def aplicar_filtros_parametro_estandar(query, campos, alias_por_catalogo, overrides_parametro) do
    query
    |> aplicar_filtros_fecha_estandar(campos, alias_por_catalogo, overrides_parametro)
    |> aplicar_filtros_string_estandar(campos, alias_por_catalogo, overrides_parametro)
    |> aplicar_filtros_numerico_estandar(campos, alias_por_catalogo, overrides_parametro)
  end

  defp campo_efectivo(campo, overrides_parametro) do
    override = Map.get(overrides_parametro, to_string(clave_campo(campo)), %{})
    defaults = Map.merge(Map.get(campo, "defaults", %{}) || %{}, Map.get(override, "defaults", %{}) || %{})
    campo |> Map.merge(Map.drop(override, ["defaults"])) |> Map.put("defaults", defaults)
  end

  # Fecha ACOTADA: rango de dos formulas/preset (mes_actual/mes_a_fecha/
  # anio_actual/formula). Fecha SIN acotar: un solo valor -- se resuelve
  # pasando el MISMO texto como "desde" y "hasta" de FiltrosDefault.
  # rango_fecha/3 (que ya sabe devolver el día completo cuando ambos
  # extremos caen en el mismo día), así el motor de fórmulas no necesita
  # saber nada de "acotado".
  defp aplicar_filtros_fecha_estandar(query, campos, alias_por_catalogo, overrides_parametro) do
    campos
    |> campos_elegibles_fecha()
    |> Enum.reduce(query, fn campo, acc ->
      efectivo = campo_efectivo(campo, overrides_parametro)
      defaults = efectivo["defaults"] || %{}
      valor_hasta = if efectivo["acotado"], do: defaults["valor_hasta"], else: defaults["valor"]

      case FiltrosDefault.rango_fecha(defaults["modo"], defaults["valor"], valor_hasta) do
        nil -> acc
        {desde, hasta} -> aplicar_filtro_estandar(acc, alias_por_catalogo, campo, {:entre, {desde, hasta}})
      end
    end)
  end

  # "like"/"igual" -- un valor (puede ser texto libre o elegido de un
  # catálogo referenciado, el filtro compara la misma columna real de
  # texto en los dos casos). "multi" -- lista de valores, comportamiento
  # OR (IN). "valor"/"valores" vacíos -- no acota.
  defp aplicar_filtros_string_estandar(query, campos, alias_por_catalogo, overrides_parametro) do
    campos
    |> campos_elegibles_string()
    |> Enum.reduce(query, fn campo, acc ->
      efectivo = campo_efectivo(campo, overrides_parametro)
      defaults = efectivo["defaults"] || %{}

      case efectivo["tipo_filtro"] || "like" do
        "like" -> aplicar_si_presente(acc, alias_por_catalogo, campo, defaults["valor"], :ilike)
        "igual" -> aplicar_si_presente(acc, alias_por_catalogo, campo, defaults["valor"], :igual)
        "multi" -> aplicar_filtro_estandar(acc, alias_por_catalogo, campo, {:in, defaults["valores"] || []})
        _ -> acc
      end
    end)
  end

  # "entre" -- dos límites (Acotado=CHECK). "mayor"/"menor"/"igual"/
  # "diferente" -- un límite (comparación estricta: "mayor que" es `>`,
  # no `>=` -- "igual" ya cubre el caso de límite inclusivo). "valor"
  # vacío -- no acota.
  defp aplicar_filtros_numerico_estandar(query, campos, alias_por_catalogo, overrides_parametro) do
    campos
    |> campos_elegibles_numerico()
    |> Enum.reduce(query, fn campo, acc ->
      efectivo = campo_efectivo(campo, overrides_parametro)
      defaults = efectivo["defaults"] || %{}
      tipo_filtro = if efectivo["acotado"], do: "entre", else: efectivo["tipo_filtro"] || "mayor"

      case tipo_filtro do
        "entre" -> aplicar_filtro_estandar(acc, alias_por_catalogo, campo, {:entre, {defaults["valor"], defaults["valor_hasta"]}})
        "mayor" -> aplicar_si_presente(acc, alias_por_catalogo, campo, defaults["valor"], :mayor)
        "menor" -> aplicar_si_presente(acc, alias_por_catalogo, campo, defaults["valor"], :menor)
        "igual" -> aplicar_si_presente(acc, alias_por_catalogo, campo, defaults["valor"], :igual)
        "diferente" -> aplicar_si_presente(acc, alias_por_catalogo, campo, defaults["valor"], :diferente)
        _ -> acc
      end
    end)
  end

  defp aplicar_si_presente(query, _alias_por_catalogo, _campo, valor, _operador) when valor in [nil, ""], do: query
  defp aplicar_si_presente(query, alias_por_catalogo, campo, valor, :ilike), do: aplicar_filtro_estandar(query, alias_por_catalogo, campo, {:ilike, valor})
  defp aplicar_si_presente(query, alias_por_catalogo, campo, valor, :igual), do: aplicar_filtro_estandar(query, alias_por_catalogo, campo, valor)
  defp aplicar_si_presente(query, alias_por_catalogo, campo, valor, :mayor), do: aplicar_filtro_estandar(query, alias_por_catalogo, campo, {:mayor, valor})
  defp aplicar_si_presente(query, alias_por_catalogo, campo, valor, :menor), do: aplicar_filtro_estandar(query, alias_por_catalogo, campo, {:menor, valor})
  defp aplicar_si_presente(query, alias_por_catalogo, campo, valor, :diferente), do: aplicar_filtro_estandar(query, alias_por_catalogo, campo, {:diferente, valor})

  defp aplicar_filtro_estandar(query, alias_por_catalogo, campo, valor) do
    alias_tabla = Map.fetch!(alias_por_catalogo, campo["catalogo"])
    aplicar_filtro(query, alias_tabla, campo_atom_real(campo), valor)
  end

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

  # "mayor que"/"menor que" del Parámetro numérico estándar -- ESTRICTOS
  # a propósito (`>`/`<`, no `>=`/`<=`): "igual" ya cubre el caso de
  # límite inclusivo.
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
  # venta/Producto) -- lista vacía es "no elegiste nada todavía", no "no
  # traigas nada": se ignora en vez de armar un WHERE false, mismo
  # criterio que un <select multiple> nativo sin nada tildado.
  defp aplicar_filtro(query, _alias_tabla, _campo, {:in, []}), do: query

  defp aplicar_filtro(query, alias_tabla, campo, {:in, lista}) do
    where(query, [{^alias_tabla, t}], field(t, ^campo) in ^lista)
  end

  defp aplicar_filtro(query, alias_tabla, campo, valor) do
    where(query, [{^alias_tabla, t}], field(t, ^campo) == ^valor)
  end

  @doc """
  `props` (shape `CatalogoGenerico.opciones_referencia/3`) para armar las
  opciones de un parámetro con origen "referenciado" -- un campo YA tipo
  "referencia" resuelve su catálogo destino real de `meta_schema_detail`
  (mismo criterio que cualquier filtro "referencia" de siempre); un
  campo "string" genuino usa el catálogo que el admin eligió a mano
  (`campo["catalogo_referenciado"]`). Los catálogos de sistema (branch/
  inventory_location/sales_unit) no tienen fila en `meta_schema_detail`
  de la que copiar "campos_acompanamiento" -- sin esto,
  `opciones_referencia/3` etiqueta cada opción "#<id>" en vez del nombre
  real, se resuelve acá de `MetaSchemaContext.catalogo_sistema/1`. `nil`
  si no se puede resolver nada (campo/catálogo raro, no debería pasar
  desde la UI).
  """
  def props_referenciado(%{"control" => true, "campo" => clave}, _detalles_por_catalogo) do
    case catalogo_control_sistema(clave) do
      nil -> nil
      catalogo -> completar_campos_acompanamiento_sistema(%{"catalogo" => catalogo})
    end
  end

  def props_referenciado(%{"tipo" => "referencia"} = campo, detalles_por_catalogo) do
    detalles_por_catalogo
    |> Map.get(campo["catalogo"], [])
    |> Enum.find(&(&1.schema_context_field == campo["campo"]))
    |> case do
      nil -> nil
      detalle -> completar_campos_acompanamiento_sistema(detalle.schema_context_properties)
    end
  end

  def props_referenciado(%{"catalogo_referenciado" => catalogo}, _detalles_por_catalogo) when is_binary(catalogo) and catalogo != "" do
    completar_campos_acompanamiento_sistema(%{"catalogo" => catalogo})
  end

  def props_referenciado(_campo, _detalles_por_catalogo), do: nil

  # Los catálogos de sistema (branch/inventory_location/sales_unit) no
  # tienen fila en meta_schema_detail de la que copiar
  # "campos_acompanamiento" -- sin esto, CatalogoGenerico.opciones_referencia/3
  # etiqueta cada opción "#<id>" en vez del nombre real. Un campo
  # "referencia" de negocio cualquiera SÍ puede traer su propio
  # "campos_acompanamiento" ya configurado por el admin -- ese se
  # respeta tal cual, nunca se pisa.
  defp completar_campos_acompanamiento_sistema(%{"catalogo" => catalogo} = props) do
    if Map.get(props, "campos_acompanamiento") in [nil, []] do
      case MetaSchemaContext.catalogo_sistema(catalogo) do
        %{campo_nombre: campo_nombre} -> Map.put(props, "campos_acompanamiento", [campo_nombre])
        nil -> props
      end
    else
      props
    end
  end

  defp completar_campos_acompanamiento_sistema(props), do: props
end
