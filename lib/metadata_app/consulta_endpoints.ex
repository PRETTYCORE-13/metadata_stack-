defmodule MetadataApp.ConsultaEndpoints do
  @moduledoc """
  Ciclo de vida del endpoint API público de una Consulta
  (SPEC-SYS-1009202602) -- CRUD + Guardar/Probar/Publicar/Despublicar,
  y (2026-09-11, R19.1) las credenciales de acceso: un endpoint puede
  tener VARIAS, cada una con su propio subconjunto de campos permitidos
  (R42-R44). Módulo separado de `MetaConsultas` a propósito (ese ya es
  grande, y esto es una pieza de configuración/seguridad, no de
  ejecución de reportes).

  Ninguna API key se guarda en texto plano ni de forma reversible
  (R25) -- solo `api_key_hash` (SHA-256, para verificar) y
  `api_key_sufijo` (4 caracteres, solo para mostrar enmascarada). La
  key completa sale ÚNICAMENTE como tercer elemento del
  `{:ok, credencial, key}` que devuelven `crear_credencial/3` y
  `regenerar_api_key_credencial/1` -- quien llama debe mostrarla una
  vez y descartarla, nunca persistirla aparte.
  """

  import Ecto.Query

  alias MetadataApp.Repo
  alias MetadataApp.Autenticacion.Empresa
  alias MetadataApp.MetaSchema.ConsultaEndpoint
  alias MetadataApp.MetaSchema.ConsultaEndpointCredencial
  alias MetadataApp.MetaSchema.ConsultaEndpointJob
  alias MetadataApp.MetaConsultas
  alias MetadataApp.BusinessProcessBuilder.MetaSchemaContext
  alias MetadataApp.BusinessProcessBuilder.CatalogoGenerico

  def obtener_por_consulta(consulta_id) do
    Repo.get_by(ConsultaEndpoint, meta_schema_consulta_id: consulta_id)
  end

  @doc "Todos los endpoints (cualquier estado), más recientes primero -- para la sección Endpoints (2026-09-14), no depende de pasar por BC List/una Consulta puntual."
  def listar_todos do
    from(e in ConsultaEndpoint, where: is_nil(e.delete_guid), order_by: [desc: e.inserted_at])
    |> Repo.all()
    |> Repo.preload(consulta: :header)
  end

  @doc """
  Borra el endpoint por completo -- en cascada (FK `on_delete: :delete_all`)
  también su Consulta interna, el Header oculto que la sostiene, y sus
  credenciales. Pensado para limpiar un endpoint que quedó a medio armar
  (ej. la sección Nuevo Endpoint crea la Consulta interna antes de que
  el admin llegue a Guardar/Publicar nada) -- mismo criterio que el
  incidente real de endpoints duplicados que motivó agregar esta acción
  (SPEC-SYS-1009202602, ver requirements.md).
  """
  def eliminar(%ConsultaEndpoint{} = endpoint) do
    endpoint = Repo.preload(endpoint, consulta: :header)
    MetaSchemaContext.eliminar_header(endpoint.consulta.header)
  end

  @doc "Solo un endpoint con estado \"publicado\" y sin baja lógica (R24) -- ya trae la Consulta precargada, el controller siempre necesita las dos."
  def obtener_publicado(metodo, ruta) do
    from(e in ConsultaEndpoint,
      where: e.metodo == ^metodo and e.ruta == ^ruta and e.estado == "publicado" and is_nil(e.delete_guid)
    )
    |> Repo.one()
    |> case do
      nil -> nil
      endpoint -> Repo.preload(endpoint, :consulta)
    end
  end

  @doc """
  Igual que `obtener_publicado/2` pero SIN filtrar por método -- los
  Jobs (R39-R41, agregado 2026-09-11) son un recurso propio
  (`.../jobs`) sobre el mismo endpoint sin importar si se configuró
  GET o POST para la invocación síncrona. Si dos endpoints distintos
  compartieran la misma `ruta` con métodos distintos (posible, la
  unicidad es por `(metodo, ruta)`), devuelve el primero que encuentre
  -- caso raro, no resuelto con más precisión en esta versión.
  """
  def obtener_publicado_por_ruta(ruta) do
    from(e in ConsultaEndpoint, where: e.ruta == ^ruta and e.estado == "publicado" and is_nil(e.delete_guid), limit: 1)
    |> Repo.one()
    |> case do
      nil -> nil
      endpoint -> Repo.preload(endpoint, :consulta)
    end
  end

  @doc """
  Crea el endpoint de `consulta` si todavía no tiene uno (R8), o
  actualiza el existente -- `empresa_id` y la Consulta dueña NUNCA
  cambian tras la primera vez que se guarda, aunque `attrs` los
  incluya (se ignoran en una actualización).
  """
  def crear_o_actualizar(consulta, attrs) do
    case obtener_por_consulta(consulta.id) do
      nil -> crear(consulta, attrs)
      existente -> actualizar(existente, attrs, consulta)
    end
  end

  defp crear(consulta, attrs) do
    attrs = Map.put(attrs, "meta_schema_consulta_id", consulta.id)

    %ConsultaEndpoint{}
    |> ConsultaEndpoint.changeset(attrs, consulta)
    |> Ecto.Changeset.change(insert_guid: generar_guid())
    |> Repo.insert()
  end

  defp actualizar(endpoint, attrs, consulta) do
    attrs = Map.drop(attrs, ["empresa_id", "meta_schema_consulta_id"])

    endpoint
    |> ConsultaEndpoint.changeset(attrs, consulta)
    |> Ecto.Changeset.change(update_guid: generar_guid())
    |> Repo.update()
  end

  @doc """
  Exporta la config de un Endpoint a JSON (SPEC-SYS-1009202602, R67) --
  NUNCA incluye nada de `ConsultaEndpointCredencial` (R69): esa tabla
  ni se lee acá, las credenciales se crean directo en cada ambiente.

  `empresa_id` se exporta como `empresa_nombre` -- un id crudo de
  Empresa no es portable entre bases (cada ambiente tiene sus propias
  filas con sus propios ids), mismo criterio que ya usa
  `MetaSchemaContext.exportar_header/2` para el maestro de un catálogo
  detalle (exporta el NOMBRE, nunca el id).

  Devuelve el nombre de la Consulta (mismo valor que
  `MetaSchemaContext.exportar_header/2`, para poder sincronizar
  huérfanos con el mismo criterio que `mix meta.export`).
  """
  def exportar_endpoint(%ConsultaEndpoint{} = endpoint, dir \\ "priv/repo/catalogos") do
    File.mkdir_p!(dir)
    endpoint = Repo.preload(endpoint, consulta: :header)
    empresa = Repo.get!(Empresa, endpoint.empresa_id)
    nombre_consulta = endpoint.consulta.header.schema_context_name

    contenido =
      Jason.encode!(
        %{
          catalogo: nombre_consulta,
          nombre: endpoint.nombre,
          metodo: endpoint.metodo,
          ruta: endpoint.ruta,
          descripcion: endpoint.descripcion,
          parametros: endpoint.parametros,
          estado: endpoint.estado,
          permite_alta: endpoint.permite_alta,
          campos_alta: endpoint.campos_alta,
          renglones_alta: endpoint.renglones_alta,
          empresa_nombre: empresa.nombre
        },
        pretty: true
      )

    File.write!(Path.join(dir, "#{nombre_consulta}.endpoint.json"), contenido)
    nombre_consulta
  end

  @doc """
  Ejecuta la Consulta con el `scope` REAL de quien está probando (el
  admin logueado en Get Config/editor de Consulta) -- nunca con una
  credencial ni acotado por `campos_permitidos` (eso solo aplica a una
  llamada externa real, R43). No exige que el endpoint esté publicado
  (R28) ni siquiera que exista todavía guardado -- por eso no recibe
  `endpoint`, solo lo que hace falta para ejecutar.
  """
  def probar(consulta, scope, overrides_parametro \\ %{}) do
    MetaConsultas.ejecutar(consulta, scope, %{}, [], nil, overrides_parametro)
  end

  @doc """
  Arma `overrides_parametro` (mismo shape que
  `ParametrosCatalogo.aplicar_filtros_parametro_estandar/4`) a partir de
  valores EXTERNOS planos (`valores_externos`, string-keyed -- query
  string en GET o body JSON en POST, R9.1) + la config de
  `endpoint.parametros` + los campos reales de `consulta`. Cualquier
  clave de `valores_externos` que no corresponda a un parámetro
  CONFIGURADO se ignora en silencio (R13 -- así un `empresa_id` que
  llegue nunca se lee para nada).

  Convención de nombres externos (decisión de implementación, sin
  requisito propio -- documentada acá y en R32): la clave externa de un
  parámetro simple es su `clave_campo` tal cual (`"<catalogo>__<campo>"`);
  un parámetro ACOTADO (rango -- fecha acotada o numérico acotado)
  necesita DOS claves externas, `"<clave>_desde"`/`"<clave>_hasta"`. Un
  parámetro string/referencia con `tipo_filtro: "multi"` acepta una
  lista JSON (POST) o texto separado por comas (GET).

  Devuelve `{:ok, overrides}` o `{:error, {:parametros_faltantes, [clave, ...]}}`
  si falta algún parámetro marcado `"obligatorio": true` (R10).
  """
  def construir_overrides(consulta, %ConsultaEndpoint{} = endpoint, valores_externos) do
    configuradas = MapSet.new(endpoint.parametros, & &1["campo"])
    obligatorias = MapSet.new(for %{"campo" => c, "obligatorio" => true} <- endpoint.parametros, do: c)

    campos =
      (MetaConsultas.campos_elegibles_fecha(consulta) ++
         MetaConsultas.campos_elegibles_string(consulta) ++
         MetaConsultas.campos_elegibles_numerico(consulta))
      |> Enum.filter(&(MapSet.member?(configuradas, campo_clave(&1))))

    {overrides, presentes} =
      Enum.reduce(campos, {%{}, MapSet.new()}, fn campo, {acc, presentes} ->
        clave = campo_clave(campo)

        case defaults_desde_externos(campo, clave, valores_externos) do
          nil -> {acc, presentes}
          defaults -> {Map.put(acc, clave, %{"defaults" => defaults}), MapSet.put(presentes, clave)}
        end
      end)

    faltantes = obligatorias |> MapSet.difference(presentes) |> MapSet.to_list()

    if faltantes == [] do
      {:ok, overrides}
    else
      {:error, {:parametros_faltantes, faltantes}}
    end
  end

  defp campo_clave(campo), do: campo |> MetaConsultas.clave_campo() |> to_string()

  defp defaults_desde_externos(%{"tipo" => "date"} = campo, clave, valores) do
    if campo["acotado"] do
      valor_rango(valores, "#{clave}_desde", "#{clave}_hasta", fn desde, hasta ->
        %{"modo" => "formula", "valor" => desde, "valor_hasta" => hasta}
      end)
    else
      case Map.get(valores, clave) do
        nil -> nil
        valor -> %{"modo" => "formula", "valor" => valor}
      end
    end
  end

  defp defaults_desde_externos(%{"tipo" => tipo} = campo, clave, valores) when tipo in ["integer", "decimal"] do
    if campo["acotado"] do
      valor_rango(valores, "#{clave}_desde", "#{clave}_hasta", fn desde, hasta ->
        %{"valor" => desde, "valor_hasta" => hasta}
      end)
    else
      case Map.get(valores, clave) do
        nil -> nil
        valor -> %{"valor" => valor}
      end
    end
  end

  # string / referencia (incluidos los campos de control -- branch/
  # sales_unit/inventory_location/trn -- que llegan con "tipo" => nil,
  # ver MetaConsultas.tipo_efectivo/1).
  defp defaults_desde_externos(campo, clave, valores) do
    case campo["tipo_filtro"] || "like" do
      "multi" ->
        case Map.get(valores, clave) do
          nil -> nil
          lista when is_list(lista) -> %{"valores" => lista}
          texto when is_binary(texto) -> %{"valores" => String.split(texto, ",", trim: true)}
        end

      _ ->
        case Map.get(valores, clave) do
          nil -> nil
          valor -> %{"valor" => valor}
        end
    end
  end

  defp valor_rango(valores, clave_desde, clave_hasta, construir) do
    case {Map.get(valores, clave_desde), Map.get(valores, clave_hasta)} do
      {nil, nil} -> nil
      {desde, hasta} -> construir.(desde, hasta)
    end
  end

  @doc "Publica el endpoint (R29) -- solo togglea `estado`, ya NO genera ninguna key acá (eso vive en las funciones de credenciales, R19.1)."
  def publicar(%ConsultaEndpoint{} = endpoint) do
    endpoint
    |> Ecto.Changeset.change(estado: "publicado", update_guid: generar_guid())
    |> Repo.update()
  end

  @doc "Vuelve a borrador (R30, R24) -- ninguna credencial, activa o no, funciona mientras el endpoint no esté publicado."
  def despublicar(%ConsultaEndpoint{} = endpoint) do
    endpoint
    |> Ecto.Changeset.change(estado: "borrador", update_guid: generar_guid())
    |> Repo.update()
  end

  # --- Alta de registros (R54-R58, agregado 2026-09-14) -------------------

  @doc """
  Inserta un registro nuevo en el catálogo base del endpoint -- MISMAS
  reglas que un alta manual desde la UI (motor de estados, folio/TRN si
  el catálogo es transaccional, validaciones de campos), vía
  `CatalogoGenerico.crear/4`, nunca un INSERT directo (R54, "a pedido
  explícito: mismas reglas que un alta manual").

  `attrs_externos` se recorta a `endpoint.campos_alta` ANTES de nada
  (R54 -- mismo criterio que `campos_permitidos` para lectura, el
  caller externo nunca puede setear un campo que el admin no habilitó
  explícitamente, aunque lo mande en el body).

  Alcance fijo a la empresa del endpoint (R55, mismo criterio que la
  lectura vía `{:empresa_fija, ...}`): se estampa `empresa_id` con
  `endpoint.empresa_id` SIEMPRE que la tabla tenga esa columna,
  pisando cualquier valor que el body externo hubiera mandado --
  nunca puede venir de afuera. Se llama a `CatalogoGenerico.crear/4`
  con el sentinel `:sistema` (no hay un Scope real de un llamador
  externo) -- por eso el estampado de empresa es manual acá, `:sistema`
  no lo hace solo.

  R65 (agregado 2026-09-17, a pedido explícito -- "puedes enviar los
  errores en vez de insertar campos vacios"): si `endpoint.campos_alta`
  tiene algo configurado pero NINGUNA clave de `attrs_externos` coincide
  con la whitelist, rechaza con `{:error, {:body_sin_coincidencias, campos_alta}}`
  en vez de insertar una fila con todos los campos de negocio en NULL.
  Caso real que motivó esto: un caller externo mandó el body con
  `Content-Type: text/plain` en vez de `application/json` -- el
  servidor nunca llegó a parsear el body (queda `attrs_externos == %{}`),
  el endpoint respondía `201` igual (todos los campos son opcionales)
  y creaba una fila vacía sin ningún aviso.
  """
  def crear_registro(%ConsultaEndpoint{permite_alta: true} = endpoint, consulta, attrs_externos) do
    case MetaSchemaContext.modulo_por_nombre(consulta.catalogo_base) do
      nil ->
        {:error, :catalogo_no_disponible}

      modulo ->
        attrs_filtrados = Map.take(attrs_externos, endpoint.campos_alta)

        if attrs_filtrados == %{} and endpoint.campos_alta != [] do
          {:error, {:body_sin_coincidencias, endpoint.campos_alta}}
        else
          with {:ok, attrs} <- resolver_referencias_por_descripcion(attrs_filtrados, consulta.catalogo_base),
               {:ok, renglones} <- renglones_spec_desde_externos(endpoint.renglones_alta, attrs_externos) do
            attrs = estampar_empresa_fija(attrs, modulo, endpoint.empresa_id)
            CatalogoGenerico.crear(modulo, :sistema, attrs, renglones: renglones)
          end
        end
    end
  end

  def crear_registro(%ConsultaEndpoint{permite_alta: false}, _consulta, _attrs_externos),
    do: {:error, :alta_no_habilitada}

  defp estampar_empresa_fija(attrs, modulo, empresa_id) do
    if :empresa_id in modulo.__schema__(:fields) do
      Map.put(attrs, "empresa_id", empresa_id)
    else
      attrs
    end
  end

  # Arma `opciones[:renglones]` de `CatalogoGenerico.crear/4` (R59-R61)
  # a partir de `attrs_externos` -- el body manda los renglones bajo la
  # clave del catálogo detalle real (ej. `"pty_lista_precios_det" =>
  # [%{...}, ...]`), cada item se recorta a los campos whitelisteados
  # para ESE catálogo detalle (mismo criterio que `campos_alta` para el
  # maestro) y sus campos "referencia" se resuelven por descripción
  # igual que en el encabezado. Cualquier catálogo detalle configurado
  # que el body no mande se omite en silencio (renglones opcionales
  # por defecto, mismo criterio que `Renglones.crear_todos/3` con
  # `%{}`).
  defp renglones_spec_desde_externos(renglones_alta, attrs_externos) do
    Enum.reduce_while(renglones_alta, {:ok, %{}}, fn %{"catalogo" => catalogo, "campos" => campos}, {:ok, acc} ->
      case Map.get(attrs_externos, catalogo) do
        items when is_list(items) ->
          case resolver_referencias_en_items(items, campos, catalogo) do
            {:ok, items_resueltos} -> {:cont, {:ok, Map.put(acc, catalogo, items_resueltos)}}
            {:error, _motivo} = error -> {:halt, error}
          end

        _otro ->
          {:cont, {:ok, acc}}
      end
    end)
  end

  defp resolver_referencias_en_items(items, campos, catalogo) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      case item |> Map.take(campos) |> resolver_referencias_por_descripcion(catalogo) do
        {:ok, item_resuelto} -> {:cont, {:ok, acc ++ [item_resuelto]}}
        {:error, _motivo} = error -> {:halt, error}
      end
    end)
  end

  @doc """
  R62-R64 (agregado 2026-09-14, revisado en el mismo día -- "regresalo
  como estaba por descripción"): cualquier campo tipo "referencia" en
  `attrs` (según el contrato real de `catalogo`, vía `meta_schema_detail`)
  se interpreta como el valor de su campo "acompañamiento" (ej.
  `pty_productos_descripcion` para `pty_lista_precios_det_productos`,
  `props["campos_acompanamiento"]` -- el MISMO campo que ya usa
  `CatalogoGenerico.opciones_referencia/3` para mostrar la etiqueta de
  un selector de referencia, no un concepto nuevo), nunca el id
  interno.

  El usuario señaló el riesgo real (misma descripción repetida en dos
  registros): acá se resuelve buscando ese valor en el catálogo
  referenciado y exigiendo EXACTAMENTE una coincidencia --
  `{:error, {:referencia_no_encontrada, campo, valor}}` si no hay
  ninguna, `{:error, {:referencia_ambigua, campo, valor}}` si hay más
  de una (nunca elige una al azar). `crear_registro/3` aborta TODO
  (encabezado + renglones) ante cualquiera de los dos.
  """
  def resolver_referencias_por_descripcion(attrs, catalogo) do
    catalogo
    |> MetaSchemaContext.listar_detalles()
    |> Enum.filter(&((&1.schema_context_properties || %{})["tipo"] == "referencia"))
    |> Enum.reduce_while({:ok, attrs}, fn detalle, {:ok, acc} ->
      campo = detalle.schema_context_field
      props = detalle.schema_context_properties
      catalogo_referenciado = props["catalogo"]
      campo_descripcion = props["campos_acompanamiento"] |> List.wrap() |> List.first()

      case Map.get(acc, campo) do
        nil ->
          {:cont, {:ok, acc}}

        valor ->
          case resolver_por_descripcion(valor, catalogo_referenciado, campo_descripcion) do
            {:ok, id} -> {:cont, {:ok, Map.put(acc, campo, id)}}
            {:error, motivo} -> {:halt, {:error, {motivo, campo, valor}}}
          end
      end
    end)
  end

  defp resolver_por_descripcion(_valor, _catalogo_referenciado, nil), do: {:error, :sin_campo_descripcion}

  defp resolver_por_descripcion(valor, catalogo_referenciado, campo_descripcion) do
    with modulo when not is_nil(modulo) <- MetaSchemaContext.modulo_por_nombre(catalogo_referenciado),
         campo_atom <- String.to_existing_atom(campo_descripcion) do
      resultado =
        from(m in modulo, where: field(m, ^campo_atom) == ^valor and is_nil(m.delete_guid), select: m.id)
        |> Repo.all()

      case resultado do
        [id] -> {:ok, id}
        [] -> {:error, :referencia_no_encontrada}
        _varios -> {:error, :referencia_ambigua}
      end
    else
      nil -> {:error, :referencia_no_encontrada}
    end
  end

  # --- Credenciales (R19.1, R42-R46, agregado 2026-09-11) -----------------

  @doc "Todas las credenciales del endpoint (activas y revocadas, R45), ordenadas por antigüedad."
  def listar_credenciales(endpoint_id) do
    from(c in ConsultaEndpointCredencial,
      where: c.meta_schema_consulta_endpoint_id == ^endpoint_id and is_nil(c.delete_guid),
      order_by: c.inserted_at
    )
    |> Repo.all()
  end

  @doc """
  Crea una credencial nueva para `endpoint` -- `attrs["campos_permitidos"]`
  se valida contra los campos VISIBLES de `consulta` (R42). No exige que
  el endpoint esté publicado (R46). Devuelve la key en claro UNA sola
  vez: `{:ok, credencial, key}`.
  """
  def crear_credencial(%ConsultaEndpoint{} = endpoint, consulta, attrs) do
    key = generar_api_key()

    attrs =
      attrs
      |> Map.put("meta_schema_consulta_endpoint_id", endpoint.id)
      |> Map.put("api_key_hash", hash_key(key))
      |> Map.put("api_key_sufijo", sufijo_key(key))

    %ConsultaEndpointCredencial{}
    |> ConsultaEndpointCredencial.changeset(attrs, claves_visibles(consulta))
    |> Ecto.Changeset.change(insert_guid: generar_guid())
    |> Repo.insert()
    |> devolver_con_key(key)
  end

  @doc "Nueva key para ESA credencial -- la anterior deja de matchear de inmediato (R23), las demás credenciales del endpoint no se tocan (R23.1). Devuelve la key en claro UNA sola vez."
  def regenerar_api_key_credencial(%ConsultaEndpointCredencial{} = credencial) do
    key = generar_api_key()

    credencial
    |> Ecto.Changeset.change(%{api_key_hash: hash_key(key), api_key_sufijo: sufijo_key(key)})
    |> Ecto.Changeset.change(update_guid: generar_guid())
    |> Repo.update()
    |> devolver_con_key(key)
  end

  @doc "Revoca una credencial puntual (R23.1) -- no borra la fila, sigue listada; las demás credenciales del endpoint no se afectan."
  def revocar_credencial(%ConsultaEndpointCredencial{} = credencial) do
    credencial
    |> Ecto.Changeset.change(estado: "revocada", update_guid: generar_guid())
    |> Repo.update()
  end

  @doc """
  Hashea `key_presentada` y busca, indexado por `api_key_hash`, una
  credencial ACTIVA de `endpoint_id` -- `nil` si no matchea ninguna
  (endpoint equivocado, key incorrecta, o la credencial fue revocada,
  R21). `Plug.Crypto.secure_compare/2` como verificación final sobre
  los hashes, defensa en profundidad además de la búsqueda indexada.
  """
  def resolver_credencial(endpoint_id, key_presentada) do
    hash = hash_key(key_presentada)

    from(c in ConsultaEndpointCredencial,
      where:
        c.meta_schema_consulta_endpoint_id == ^endpoint_id and c.api_key_hash == ^hash and c.estado == "activa" and
          is_nil(c.delete_guid)
    )
    |> Repo.one()
    |> case do
      nil -> nil
      credencial -> if Plug.Crypto.secure_compare(hash, credencial.api_key_hash), do: credencial, else: nil
    end
  end

  # --- Jobs asíncronos (R39-R41, agregado 2026-09-11) --------------------

  @doc "Encola la extracción completa como Job de Oban -- devuelve el registro de estado, consultable después."
  def crear_job(endpoint, credencial, overrides_parametro) do
    {:ok, job} =
      %ConsultaEndpointJob{}
      |> ConsultaEndpointJob.changeset(%{
        "meta_schema_consulta_endpoint_id" => endpoint.id,
        "meta_schema_consulta_endpoint_credencial_id" => credencial.id
      })
      |> Repo.insert()

    {:ok, oban_job} =
      %{"job_id" => job.id, "overrides" => overrides_parametro}
      |> MetadataApp.Workers.ConsultaEndpointJob.new()
      |> Oban.insert()

    actualizar_job(job, %{"oban_job_id" => oban_job.id})

    # Re-leer, NUNCA devolver el `job` en memoria de arriba -- bajo
    # `testing: :inline` (config/test.exs) Oban.insert/1 ya corrió
    # perform/1 sincrónico ANTES de esta línea, así que el struct viejo
    # todavía diría "pendiente" aunque la fila real ya esté
    # "completado"/"fallido".
    {:ok, obtener_job(job.id)}
  end

  def obtener_job(job_id), do: Repo.get(ConsultaEndpointJob, job_id)

  def marcar_job_en_curso(job), do: actualizar_job(job, %{"estado" => "en_curso"})

  def marcar_job_completado(job, archivo_resultado, cantidad_registros) do
    actualizar_job(job, %{"estado" => "completado", "archivo_resultado" => archivo_resultado, "cantidad_registros" => cantidad_registros})
  end

  def marcar_job_fallido(job, mensaje_error), do: actualizar_job(job, %{"estado" => "fallido", "error" => mensaje_error})

  defp actualizar_job(job, attrs) do
    {:ok, actualizado} = job |> ConsultaEndpointJob.changeset(attrs) |> Repo.update()
    actualizado
  end

  defp claves_visibles(consulta) do
    consulta.campos
    |> Enum.filter(&(&1["visible"] == true))
    |> Enum.map(&(&1 |> MetaConsultas.clave_campo() |> to_string()))
  end

  defp devolver_con_key({:ok, registro}, key), do: {:ok, registro, key}
  defp devolver_con_key(error, _key), do: error

  defp generar_api_key, do: :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  defp hash_key(key), do: :crypto.hash(:sha256, key) |> Base.encode16(case: :lower)
  defp sufijo_key(key), do: String.slice(key, -4, 4)

  defp generar_guid, do: Ecto.UUID.generate() |> String.replace("-", "")
end
