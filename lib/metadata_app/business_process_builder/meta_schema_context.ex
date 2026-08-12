defmodule MetadataApp.BusinessProcessBuilder.MetaSchemaContext do
  alias MetadataApp.Repo
  alias MetadataApp.BusinessProcessBuilder.MetaSchema.Header
  alias MetadataApp.BusinessProcessBuilder.MetaSchema.Detail
  alias MetadataApp.BusinessProcessBuilder.MetaSchema.CarpetaOrden
  import Ecto.Query

  # order_by explícito a propósito: sin esto Postgres no garantiza el orden
  # de las filas devueltas, y mix meta.export terminaba produciendo diffs
  # sin sentido (el archivo entero "cambiaba" de orden) sin ningún cambio
  # real en la base.
  def listar_headers do
    from(h in Header, where: is_nil(h.delete_guid), order_by: h.schema_context_name)
    |> Repo.all()
  end

  @doc """
  Buscador acotado de catálogos RAÍZ (no carpeta, no detalle) por nombre o
  etiqueta — para el picker de exportar un tepache (ver
  `MetadataApp.MetaTepache.exportar/1`). A diferencia de
  `Permissions.buscar_catalogos/2` (pensado para Permission Sets), acá NO
  se exige que tenga transiciones — un catálogo simple sin motor de
  estados también se puede empaquetar. Mismo criterio de escala que el
  resto del RBAC: nunca la lista completa, siempre acotado por texto +
  límite.
  """
  def buscar_catalogos_raiz(query, limite \\ 20)

  def buscar_catalogos_raiz("", _limite), do: []

  def buscar_catalogos_raiz(query, limite) do
    texto = "%#{query}%"

    Repo.all(
      from h in Header,
        where:
          is_nil(h.delete_guid) and h.schema_context_type != 2 and is_nil(h.schema_encabezado_id) and
            (ilike(h.schema_context_name, ^texto) or ilike(h.schema_context_label, ^texto)),
        order_by: h.schema_context_label,
        limit: ^limite,
        select: %{recurso: h.schema_context_name, label: h.schema_context_label}
    )
  end

  # Ítems del sidebar: un catálogo visible = una entrada de menú.
  def listar_menu do
    from(h in Header, where: is_nil(h.delete_guid) and h.schema_visible == true)
    |> Repo.all()
    |> Enum.map(fn h ->
      %{id: h.schema_context_name, label: h.schema_context_label, nav: h.schema_context_nav}
    end)
  end

  # Igual que listar_menu/0 pero en árbol: cada segmento del nav (menos el
  # último) es una carpeta y el último segmento es la página. Ej.
  # nav="/catalogos/carros" -> carpeta "catalogos" con la página "Carros"
  # adentro. Estilo explorador de Windows: carpetas primero (orden
  # alfabético), luego páginas (por etiqueta).
  def listar_menu_arbol do
    from(h in Header, where: is_nil(h.delete_guid) and h.schema_visible == true)
    |> Repo.all()
    |> Enum.map(&item_de_header/1)
    |> construir_arbol()
  end

  # Mismo árbol, pero con TODOS los contextos (visibles o no) — para la
  # tabla de administración (BC List), que necesita mostrarlos todos.
  def listar_headers_arbol do
    from(h in Header, where: is_nil(h.delete_guid))
    |> Repo.all()
    |> Enum.map(&item_de_header/1)
    |> construir_arbol()
  end

  def item_de_header(h) do
    %{
      id: h.schema_context_name,
      header_id: h.id,
      schema_encabezado_id: h.schema_encabezado_id,
      label: h.schema_context_label,
      nav: h.schema_context_nav,
      visible: h.schema_visible,
      icono: h.schema_context_icono,
      orden: h.orden,
      es_carpeta: h.schema_context_type == 2,
      es_consulta: h.schema_context_type == 3
    }
  end

  # Recibe una lista de %{id:, label:, nav:, es_carpeta:, ...} y arma el
  # árbol de carpetas/páginas a partir del nav de cada uno. Cualquier llave
  # extra en el item (ej. :visible) sobrevive en el nodo de página
  # resultante. Un item con es_carpeta: true no genera página — solo declara
  # (o le pone nombre bonito a) la carpeta en esa ruta.
  def construir_arbol(items) do
    ordenes_implicitas = cargar_ordenes_implicitas()

    items
    |> Enum.reduce(%{}, fn item, arbol ->
      if item.es_carpeta do
        insertar_carpeta_explicita(arbol, segmentos(item.nav), item.label, item[:icono], item.id, item[:orden], "", ordenes_implicitas)
      else
        insertar_en_arbol(arbol, segmentos_con_carpeta(item), item, "", ordenes_implicitas)
      end
    end)
    |> mapa_a_lista_ordenada()
  end

  # Orden manual de carpetas IMPLÍCITAS (ver moduledoc de CarpetaOrden),
  # indexado por ruta acumulada — se carga una sola vez por árbol en vez
  # de una consulta por carpeta.
  defp cargar_ordenes_implicitas do
    from(c in CarpetaOrden, select: {c.ruta, c.orden})
    |> Repo.all()
    |> Map.new()
  end

  defp segmentos(nav), do: nav |> String.trim_leading("/") |> String.split("/", trim: true)

  # Nunca se deja un catálogo suelto al nivel raíz del menú — si el nav no
  # trae carpeta (ej. "/refacciones", un solo segmento) se envuelve en una
  # carpeta con el nombre de la propia etiqueta del catálogo (no un genérico
  # "general"). Si el nav sí trae carpeta (ej. "/refacciones/algo"), esa
  # carpeta usa el segmento real de la ruta, como siempre.
  defp segmentos_con_carpeta(item) do
    case segmentos(item.nav) do
      [] -> [item.label, item.id]
      [pagina] -> [item.label, pagina]
      varios -> varios
    end
  end

  defp insertar_en_arbol(mapa, [ultimo], item, _ruta_padre, _ordenes_implicitas) do
    Map.put(mapa, {:pagina, ultimo}, item)
  end

  defp insertar_en_arbol(mapa, [], item, _ruta_padre, _ordenes_implicitas) do
    # nav sin segmentos (ej. "/") — no debería pasar con la validación
    # actual, pero por si acaso no se pierde el ítem.
    Map.put(mapa, {:pagina, item.id}, item)
  end

  defp insertar_en_arbol(mapa, [carpeta | resto], item, ruta_padre, ordenes_implicitas) do
    ruta = ruta_con(ruta_padre, carpeta)

    nodo_default = %{
      nombre: nil,
      icono: nil,
      id: nil,
      orden: Map.get(ordenes_implicitas, ruta),
      hijos: insertar_en_arbol(%{}, resto, item, ruta, ordenes_implicitas)
    }

    Map.update(mapa, {:carpeta, carpeta}, nodo_default, fn nodo ->
      %{nodo | hijos: insertar_en_arbol(nodo.hijos, resto, item, ruta, ordenes_implicitas)}
    end)
  end

  # Una carpeta explícita (registro tipo :carpeta) recorre/crea cada nivel
  # de su nav igual que insertar_en_arbol/3, pero en el nivel final no deja
  # una página — le pone su propio label como nombre "bonito" de esa
  # carpeta (y su ícono, si tiene uno configurado), en vez del segmento
  # crudo de la URL. `id` (schema_context_name del Header que la declara)
  # viaja también, para que la UI de administración sepa qué carpeta tiene
  # un Header real detrás (editable/eliminable) y cuál es solo un segmento
  # de ruta inferido de sus hijos (no hay nada que editar/eliminar ahí).
  defp insertar_carpeta_explicita(mapa, [], _label, _icono, _id, _orden, _ruta_padre, _ordenes_implicitas), do: mapa

  defp insertar_carpeta_explicita(mapa, [ultimo], label, icono, id, orden, _ruta_padre, _ordenes_implicitas) do
    # Map.merge en vez de %{nodo | ...}: si esta carpeta ya existía en el
    # mapa como nodo "inferido" (creado por insertar_en_arbol/3 al procesar
    # una página hija que se coló primero en el Enum.reduce — el orden
    # depende del orden alfabético de schema_context_name, no del nav), ese
    # nodo no tiene las claves :icono/:id/:orden todavía. %{nodo | ...}
    # exige que ya existan (KeyError si no) — Map.merge las agrega sin
    # problema.
    Map.update(mapa, {:carpeta, ultimo}, %{nombre: label, icono: icono, id: id, orden: orden, hijos: %{}}, fn nodo ->
      Map.merge(nodo, %{nombre: label, icono: icono, id: id, orden: orden})
    end)
  end

  defp insertar_carpeta_explicita(mapa, [seg | resto], label, icono, id, orden, ruta_padre, ordenes_implicitas) do
    ruta = ruta_con(ruta_padre, seg)

    nodo_default = %{
      nombre: nil,
      icono: nil,
      id: nil,
      orden: Map.get(ordenes_implicitas, ruta),
      hijos: insertar_carpeta_explicita(%{}, resto, label, icono, id, orden, ruta, ordenes_implicitas)
    }

    Map.update(mapa, {:carpeta, seg}, nodo_default, fn nodo ->
      %{nodo | hijos: insertar_carpeta_explicita(nodo.hijos, resto, label, icono, id, orden, ruta, ordenes_implicitas)}
    end)
  end

  defp ruta_con("", segmento), do: segmento
  defp ruta_con(ruta_padre, segmento), do: ruta_padre <> "/" <> segmento

  defp mapa_a_lista_ordenada(mapa) do
    mapa
    |> Enum.map(fn
      {{:pagina, _clave}, item} ->
        Map.put(item, :tipo, :pagina)

      {{:carpeta, segmento}, nodo} ->
        %{
          tipo: :carpeta,
          segmento: segmento,
          nombre: nodo.nombre || segmento,
          icono: Map.get(nodo, :icono),
          id: Map.get(nodo, :id),
          orden: Map.get(nodo, :orden),
          hijos: mapa_a_lista_ordenada(nodo.hijos)
        }
    end)
    |> Enum.sort_by(&clave_orden/1)
    |> reordenar_detalles_bajo_maestro()
  end

  # Con orden manual asignado (drag-and-drop, "Editar vista" en
  # BcListLive) — carpeta O página compiten en el MISMO pool numérico, así
  # se pueden intercalar libremente entre sí (una carpeta antes que un
  # catálogo, o al revés, lo que el admin haya arrastrado). Sin orden
  # asignado, cae al criterio de siempre: carpetas alfabéticas primero,
  # páginas alfabéticas después — y eso siempre queda DESPUÉS de cualquier
  # ítem con orden manual, mezclado o no.
  #
  # Las tuplas de las tres cláusulas tienen que tener la MISMA aridad a
  # propósito: Erlang/Elixir ordena tuplas por tamaño ANTES que por
  # contenido, así que una de 2 elementos y otra de 3 nunca se comparan
  # por el primer elemento como uno esperaría — quedan siempre agrupadas
  # por tamaño primero, rompiendo el criterio "va antes/después" que se
  # busca acá.
  defp clave_orden(%{orden: orden} = nodo) when not is_nil(orden), do: {0, orden, texto_nodo(nodo)}
  defp clave_orden(%{tipo: :carpeta, nombre: nombre}), do: {1, 0, nombre}
  defp clave_orden(%{tipo: :pagina, label: label}), do: {1, 1, label}

  defp texto_nodo(%{tipo: :carpeta, nombre: nombre}), do: nombre
  defp texto_nodo(%{tipo: :pagina, label: label}), do: label

  # Catálogo Maestro-Detalle: el orden alfabético por label (de arriba) no
  # tiene por qué dejar a un detalle cerca de su maestro (ej. "ECC Det"
  # ordena antes que "ECC - Ennova..." si el label no coincide a propósito).
  # Acá, DENTRO de cada nivel del árbol (una carpeta a la vez, ya
  # recursivo por venir de mapa_a_lista_ordenada/1), cualquier página que
  # sea detalle de OTRA página presente en el mismo nivel se saca de su
  # posición alfabética y se reinserta justo debajo de su maestro, en
  # orden de creación entre sí (header_id ascendente). Un detalle cuyo
  # maestro no está en este mismo nivel (otra carpeta, o filtrado por
  # búsqueda/paginación) se queda donde el orden alfabético lo puso —
  # no hay maestro visible con quien agruparlo.
  defp reordenar_detalles_bajo_maestro(nodos) do
    # header_id (PK numérica) — no confundir con :id (schema_context_name,
    # string): schema_encabezado_id de un detalle apunta al header_id
    # numérico del maestro, así que la membresía "¿el maestro está en este
    # mismo nivel?" tiene que chequearse contra header_id, no contra :id.
    header_ids_presentes =
      nodos
      |> Enum.filter(&(&1.tipo == :pagina))
      |> MapSet.new(& &1.header_id)

    detalles_por_maestro =
      nodos
      |> Enum.filter(fn
        %{tipo: :pagina, schema_encabezado_id: id} -> not is_nil(id) and MapSet.member?(header_ids_presentes, id)
        _ -> false
      end)
      |> Enum.group_by(& &1.schema_encabezado_id)
      |> Map.new(fn {maestro_id, detalles} -> {maestro_id, Enum.sort_by(detalles, & &1.header_id)} end)

    header_ids_ya_agrupados =
      detalles_por_maestro |> Map.values() |> List.flatten() |> MapSet.new(& &1.header_id)

    Enum.flat_map(nodos, fn nodo ->
      cond do
        nodo.tipo == :pagina and MapSet.member?(header_ids_ya_agrupados, nodo.header_id) ->
          []

        nodo.tipo == :pagina and Map.has_key?(detalles_por_maestro, nodo.header_id) ->
          [nodo | Map.fetch!(detalles_por_maestro, nodo.header_id)]

        true ->
          [nodo]
      end
    end)
  end

  # Lista plana de todas las carpetas que ya existen (declaradas o
  # inferidas), con su ruta real (para armar el nav) y una etiqueta tipo
  # "migas de pan" (para el selector "Carpeta padre" del formulario). Ej.
  # %{ruta: "vehiculos/electricos", etiqueta: "vehiculos / Eléctricos"}.
  def listar_carpetas_existentes do
    listar_headers_arbol()
    |> recolectar_carpetas("", "")
    |> Enum.sort_by(& &1.etiqueta)
  end

  defp recolectar_carpetas(nodos, ruta_previa, etiqueta_previa) do
    Enum.flat_map(nodos, fn
      %{tipo: :carpeta, segmento: segmento, nombre: nombre, hijos: hijos} ->
        ruta = if ruta_previa == "", do: segmento, else: ruta_previa <> "/" <> segmento
        etiqueta = if etiqueta_previa == "", do: nombre, else: etiqueta_previa <> " / " <> nombre

        [%{ruta: ruta, etiqueta: etiqueta} | recolectar_carpetas(hijos, ruta, etiqueta)]

      %{tipo: :pagina} ->
        []
    end)
  end

  # Catálogos reales (no carpetas) que un campo tipo "referencia" puede
  # apuntar — usado por el selector "Catálogo destino" del modal "Agregar
  # campo" (BcNuevoCompletoLive y BcMotorLive). Sin esto, "referencia" era
  # un tipo seleccionable pero sin forma de elegir a qué apuntaba, y
  # CatalogoGenerador.generar/1 fallaba en silencio al no encontrar esa
  # propiedad (ver construir_opciones/2 en catalogo_generador.ex).
  def listar_catalogos_referenciables do
    from(h in Header, where: is_nil(h.delete_guid) and h.schema_context_type == 1, order_by: h.schema_context_label)
    |> Repo.all()
    |> Enum.map(&%{nombre: &1.schema_context_name, etiqueta: &1.schema_context_label})
  end

  def obtener_header!(id), do: Repo.get!(Header, id)

  # Catálogos detalle de UN maestro (schema_encabezado_id == header_maestro_id)
  # — usado por MetaEstadosAdmin.validar_campos_editables/1 (Fase 3, R4) para
  # aceptar en una transición del maestro tanto sus propios campos como los
  # de cualquiera de sus catálogos detalle, y por meta_campos_por_detalle/1
  # y BcMotorLive (Fase 4, R7/R10).
  def listar_catalogos_detalle(header_maestro_id) do
    from(h in Header, where: is_nil(h.delete_guid) and h.schema_encabezado_id == ^header_maestro_id)
    |> Repo.all()
  end

  # Bloque de meta_campos por cada catálogo detalle de un maestro (Fase 4,
  # R10) — %{} si no tiene detalles, para que el contrato de siempre no
  # gane una llave nueva en el caso común (retrocompatible). Mismo shape
  # que "meta_campos" de siempre, uno por catálogo detalle.
  def meta_campos_por_detalle(header_maestro_id) do
    header_maestro_id
    |> listar_catalogos_detalle()
    |> Map.new(fn h -> {h.schema_context_name, h.schema_context_name |> listar_detalles() |> Enum.map(&serializar_detalle/1)} end)
  end

  # Catálogos que se pueden elegir como maestro al crear un detalle — un
  # catálogo real (no carpeta) que a su vez NO sea ya detalle de otro
  # (evita ofrecer multinivel desde la UI, ver header.ex/validar_encabezado).
  def listar_catalogos_maestro_candidatos do
    from(h in Header,
      where: is_nil(h.delete_guid) and h.schema_context_type == 1 and is_nil(h.schema_encabezado_id),
      order_by: h.schema_context_label
    )
    |> Repo.all()
    |> Enum.map(&%{nombre: &1.schema_context_name, etiqueta: &1.schema_context_label})
  end

  # schema_context_name cubre hoy el rol que antes cumplían schema_nombre y
  # tabla por separado: identifica el catálogo y es el nombre físico de la
  # tabla de Postgres.
  def obtener_header_por_nombre(schema_context_name) do
    Repo.one(
      from h in Header, where: h.schema_context_name == ^schema_context_name and is_nil(h.delete_guid)
    )
  end

  @doc """
  Igual que `obtener_header_por_nombre/1` pero para varios nombres a la
  vez (`WHERE schema_context_name IN (...)`) — una sola query en vez de
  una por nombre. Pensado para pantallas que resuelven una lista de
  catálogos a partir de nombres ya conocidos (ver `UsuariosEmpresaLive`,
  columna "BC" del detalle de usuario: un header por cada recurso con
  permiso de lectura). Nombres sin header (o borrado) simplemente no
  aparecen en el resultado, mismo criterio que la versión singular
  devolviendo `nil`.
  """
  def obtener_headers_por_nombres(schema_context_names) do
    from(h in Header, where: h.schema_context_name in ^schema_context_names and is_nil(h.delete_guid))
    |> Repo.all()
  end

  # Antes de dejar borrar una carpeta hay que confirmar que no tenga nada
  # colgando debajo (otra carpeta o un catálogo) — eliminar_header/1 hace un
  # DELETE físico, así que si se permitiera igual, esos hijos quedarían
  # técnicamente intactos pero sin la carpeta que los agrupa/nombra. Se
  # consulta directo contra la tabla (no el árbol ya armado en memoria) para
  # que la regla valga incluso si el árbol que tiene el cliente está viejo.
  def tiene_hijos_en_nav?(nav) do
    prefijo = nav <> "/"

    from(h in Header, where: is_nil(h.delete_guid) and like(h.schema_context_nav, ^"#{prefijo}%"))
    |> Repo.exists?()
  end

  # Resuelve el catálogo a partir de la ruta de navegación guardada en el
  # header (schema_context_nav) — no siempre coincide con schema_context_name
  # (ej. nav "/catalogos/carros" para el catálogo "pty_carros"), así que la
  # pantalla genérica de catálogo busca por este campo, no por el nombre.
  def obtener_header_por_nav(nav) do
    Repo.one(
      from h in Header, where: h.schema_context_nav == ^nav and is_nil(h.delete_guid)
    )
  end

  # Resuelve el módulo Ecto (ej. MetadataApp.MetaBusinessProcess.Catalogos.PtyMoto)
  # a partir del nombre — se deriva en el momento, no se guarda: es determinista.
  def modulo_por_nombre(schema_context_name) do
    with %Header{} <- obtener_header_por_nombre(schema_context_name),
         modulo <- Module.concat(MetadataApp.MetaBusinessProcess.Catalogos, Macro.camelize(schema_context_name)),
         true <- Code.ensure_loaded?(modulo) do
      modulo
    else
      _ -> nil
    end
  end

  # Agrupación visual de campos en el formulario de la Ficha 360° → tab
  # Detalle (acordeones — ver FichaLive.acordeones_detalle/1, configurado
  # por campo desde BcMotorLive → Campos → "Categoría"). Vocabulario
  # cerrado a propósito (nada de texto libre): así el orden de los
  # acordeones es siempre el mismo sin importar el catálogo, y no hay
  # forma de terminar con "Impuesto"/"impuestos"/"IMPUESTOS" como 3
  # categorías distintas por typo. "info_general" es el default para
  # cualquier campo que nunca se haya tocado (catálogos ya existentes
  # antes de esto) — ver categoria_campo/1.
  @categorias_campo [
    {"info_general", "Información general"},
    {"impuestos", "Impuestos"},
    {"descuentos", "Descuentos"},
    {"entrega_logistica", "Entrega y logística"},
    {"personalizados", "Campos personalizados"},
    {"observaciones", "Observaciones"}
  ]

  def categorias_campo, do: @categorias_campo

  def etiqueta_categoria_campo(codigo), do: Map.get(Map.new(@categorias_campo), codigo, "Información general")

  # Categoría efectiva de un detalle (struct o mapa con "categoria" en
  # schema_context_properties) — nunca nil, cae al default si no está
  # configurada o si trae un código que ya no existe en el vocabulario.
  def categoria_campo(%{schema_context_properties: props}), do: categoria_campo(props)

  def categoria_campo(%{} = props) do
    codigo = Map.get(props, "categoria")
    if codigo in Enum.map(@categorias_campo, &elem(&1, 0)), do: codigo, else: "info_general"
  end

  # Columnas curadas de la tabla del tab Detalle (Ficha 360°) — con
  # catálogos de 30+ campos, mostrar TODOS como columna en una tabla ancha
  # es inusable; esto deja elegir por campo (BcMotorLive → Campos → "En
  # tabla") cuáles se ven ahí. Opt-OUT (default true) a propósito, no
  # opt-in: así ningún catálogo ya existente pierde columnas de la tabla
  # de un día para el otro sin que nadie lo haya configurado — el
  # formulario de al lado siempre sigue mostrando TODOS los campos
  # visibles, sin importar esto (ver FichaLive.formulario_renglon/1).
  def mostrar_en_tabla?(%{schema_context_properties: props}), do: mostrar_en_tabla?(props)
  def mostrar_en_tabla?(%{} = props), do: Map.get(props, "mostrar_en_tabla", true) != false

  def listar_detalles(schema_context_name) do
    from(d in Detail,
      join: h in assoc(d, :header),
      where: h.schema_context_name == ^schema_context_name,
      where: is_nil(d.delete_guid),
      where: is_nil(h.delete_guid),
      order_by: [asc: fragment("(?->>'orden')::integer", d.schema_context_properties), asc: d.id]
    )
    |> Repo.all()
  end

  @doc """
  Igual que `listar_detalles/1` pero para TODOS los catálogos a la vez,
  agrupados por `schema_context_name` — una sola query en vez de una por
  catálogo. Pensado para pantallas que necesitan los detalles de todos los
  catálogos del sistema (ver `PlantillaConstructorLive`, panel de "Campo
  calculado": cualquier catálogo puede usarse en una fórmula, no solo los
  relacionados). Un catálogo sin detalles simplemente no aparece como
  llave — usar `Map.get(mapa, nombre, [])` del lado del caller.
  """
  def listar_detalles_de_todos_los_catalogos do
    from(d in Detail,
      join: h in assoc(d, :header),
      where: is_nil(d.delete_guid),
      where: is_nil(h.delete_guid),
      order_by: [asc: fragment("(?->>'orden')::integer", d.schema_context_properties), asc: d.id],
      select: {h.schema_context_name, d}
    )
    |> Repo.all()
    |> Enum.group_by(fn {nombre, _detalle} -> nombre end, fn {_nombre, detalle} -> detalle end)
  end

  @doc """
  Igual que `listar_detalles_de_todos_los_catalogos/0` pero acotado a una
  lista de nombres puntual — una sola query para varios catálogos ya
  conocidos, en vez de traer el universo entero cuando no hace falta (ver
  `expandir_referencias/2` y `ordenar_por_dependencias/1`, que resuelven
  la clausura de referencias de un paquete a publicar por niveles, no
  cargando TODOS los catálogos del sistema — mismo criterio de escala que
  el resto del BPB, pensado para +1000 catálogos posibles).
  """
  def listar_detalles_de_varios(schema_context_names) do
    from(d in Detail,
      join: h in assoc(d, :header),
      where: h.schema_context_name in ^schema_context_names,
      where: is_nil(d.delete_guid),
      where: is_nil(h.delete_guid),
      order_by: [asc: fragment("(?->>'orden')::integer", d.schema_context_properties), asc: d.id],
      select: {h.schema_context_name, d}
    )
    |> Repo.all()
    |> Enum.group_by(fn {nombre, _detalle} -> nombre end, fn {_nombre, detalle} -> detalle end)
  end

  # schema_context_name de todo catálogo que bloquea el borrado total de
  # schema_context_name -- dos motivos distintos, unificados en una sola
  # lista porque ambos usan el mismo mensaje/UX ("catálogo(s)
  # dependientes, borralos primero"):
  #
  #   1) tiene un detalle tipo "referencia" apuntando acá (de siempre).
  #   2) es un catálogo DETALLE de este maestro (schema_encabezado_id
  #      apunta acá) -- encontrado en vivo (2026-08-11): meta_schema_header.
  #      schema_encabezado_id SÍ tiene FK real (RESTRICT, sin ON DELETE)
  #      contra meta_schema_header(id), pero nada acá lo chequeaba antes
  #      de intentar el DELETE -- el borrado de un maestro con detalle
  #      vivo llegaba hasta el DROP TABLE/DELETE real y explotaba con un
  #      error crudo de Postgres en vez de bloquearse limpio como
  #      cualquier otro dependiente.
  def listar_dependientes(schema_context_name) do
    referencias =
      from(d in Detail,
        join: h in assoc(d, :header),
        where: is_nil(d.delete_guid),
        where: is_nil(h.delete_guid),
        where: fragment("?->>'tipo'", d.schema_context_properties) == "referencia",
        where: fragment("?->>'catalogo'", d.schema_context_properties) == ^schema_context_name,
        distinct: true,
        select: h.schema_context_name
      )
      |> Repo.all()

    detalles =
      from(h in Header,
        join: maestro in Header,
        on: maestro.id == h.schema_encabezado_id,
        where: is_nil(h.delete_guid) and is_nil(maestro.delete_guid),
        where: maestro.schema_context_name == ^schema_context_name,
        select: h.schema_context_name
      )
      |> Repo.all()

    Enum.uniq(referencias ++ detalles)
  end

  # --- Referencias dependientes ("combos en cascada") ------------------------
  #
  # Un campo tipo "referencia" puede traer una lista "dependencias" en su
  # schema_context_properties: [%{"campo_padre" => ..., "campo_remoto" =>
  # ..., "obligatorio" => bool}, ...] — "campo_padre" es OTRO campo
  # "referencia" del MISMO catálogo (ej. "Estado" en el formulario de
  # "Municipio"), "campo_remoto" es una columna del catálogo DESTINO de
  # ESTE campo (ej. "estado_id" en la tabla "municipios") que tiene que
  # coincidir con el valor actual del padre. Encadenable a cualquier
  # profundidad (Estado→Municipio→Localidad) simplemente configurando cada
  # eslabón por separado — no hay ningún nombre de campo fijo en este
  # motor, todo sale de la metadata.

  @doc "Campos tipo \"referencia\" de `catalogo` que tienen \"dependencias\" configuradas (lista no vacía)."
  def campos_con_dependencias(catalogo) do
    catalogo
    |> listar_detalles()
    |> Enum.filter(fn d ->
      props = d.schema_context_properties
      props["tipo"] == "referencia" and is_list(props["dependencias"]) and props["dependencias"] != []
    end)
  end

  @doc """
  Campos de `catalogo` que dependen de `campo`, directa o
  transitivamente (Municipio Y Localidad si `campo` es Estado) — para
  limpiarlos en cascada cuando el usuario cambia el valor de `campo`.
  BFS sobre el grafo campo→dependientes armado con `listar_detalles/1`;
  auto-termina aunque el grafo tuviera un ciclo (cada nombre se visita
  una sola vez).
  """
  def descendientes(catalogo, campo) do
    todos = listar_detalles(catalogo)

    hijos_de = fn nombre ->
      todos
      |> Enum.filter(fn d ->
        props = d.schema_context_properties
        is_list(props["dependencias"]) and Enum.any?(props["dependencias"], &(&1["campo_padre"] == nombre))
      end)
      |> Enum.map(& &1.schema_context_field)
    end

    descendientes_bfs([campo], hijos_de, MapSet.new())
  end

  defp descendientes_bfs([], _hijos_de, acumulado), do: MapSet.to_list(acumulado)

  defp descendientes_bfs([nombre | resto], hijos_de, acumulado) do
    nuevos = nombre |> hijos_de.() |> Enum.reject(&MapSet.member?(acumulado, &1))
    descendientes_bfs(resto ++ nuevos, hijos_de, Enum.reduce(nuevos, acumulado, &MapSet.put(&2, &1)))
  end

  @doc """
  Vacía en `valores` (mapa `%{"campo" => valor}` del registro/renglón que
  se está editando) cualquier campo que dependa de `campo_cambiado` — se
  llama cuando el usuario le cambia el valor a un campo referencia, para
  que sus hijos no queden con un valor que dejó de ser válido para el
  nuevo padre (ej. cambiar Estado vacía Municipio y Localidad).
  """
  def limpiar_descendientes(catalogo, campo_cambiado, valores) do
    catalogo
    |> descendientes(campo_cambiado)
    |> Enum.reduce(valores, &Map.put(&2, &1, ""))
  end

  @doc """
  Valida que configurar `dependencias_propuestas` en `campo` (dentro de
  `catalogo`) no arme un ciclo (A depende de B que depende de A, directo
  o indirecto) — se llama ANTES de persistir la config (a diferencia del
  resto de este motor, acá NO es fail-open: un ciclo mal configurado se
  rechaza con un mensaje claro, nunca se guarda). Mismo patrón `MapSet`
  "en_progreso" que `MetaPlantillas.Formula.resolver_uno/4` usa para
  cortar ciclos entre campos calculados.
  """
  def validar_sin_ciclo(catalogo, campo, dependencias_propuestas) do
    todos = listar_detalles(catalogo)

    padres_de = fn
      ^campo ->
        dependencias_propuestas |> Enum.map(& &1["campo_padre"]) |> Enum.reject(&(&1 in [nil, ""]))

      nombre ->
        case Enum.find(todos, &(&1.schema_context_field == nombre)) do
          nil ->
            []

          detalle ->
            (detalle.schema_context_properties["dependencias"] || [])
            |> Enum.map(& &1["campo_padre"])
            |> Enum.reject(&(&1 in [nil, ""]))
        end
    end

    case buscar_ciclo(campo, padres_de, MapSet.new()) do
      :ok -> :ok
      {:ciclo, cadena} -> {:error, "\"#{campo}\" formaría un ciclo de dependencias: #{Enum.join(cadena, " → ")}"}
    end
  end

  defp buscar_ciclo(nombre, padres_de, en_progreso) do
    if MapSet.member?(en_progreso, nombre) do
      {:ciclo, [nombre]}
    else
      en_progreso2 = MapSet.put(en_progreso, nombre)

      nombre
      |> padres_de.()
      |> Enum.reduce_while(:ok, fn padre, :ok ->
        case buscar_ciclo(padre, padres_de, en_progreso2) do
          :ok -> {:cont, :ok}
          {:ciclo, cadena} -> {:halt, {:ciclo, [nombre | cadena]}}
        end
      end)
    end
  end

  @doc """
  Dado un campo referencia con `"dependencias"` (`props`, su
  `schema_context_properties`) y el mapa de valores actuales de sus
  campos hermanos (`valores_hermanos`, del registro/renglón en edición —
  header o renglón, mismo mapa que ya reciben `campo_row/1`/
  `formulario_renglon/1`), resuelve si puede calcularse sus opciones
  ahora: `{:ok, filtros}` (mapa listo para
  `CatalogoGenerico.opciones_referencia/2`) o `{:disabled, mensaje}` si
  falta el valor de un padre `"obligatorio"` (default `true` si la
  dependencia no dice nada — mismo criterio "obligatoria salvo que se
  diga lo contrario" que el resto del contrato). `campos_hermanos`
  (structs `Detail`, opcional) solo se usa para armar un mensaje
  automático con la ETIQUETA del padre en vez de su nombre técnico,
  cuando no hay `"mensaje_sin_padre"` configurado a mano.
  """
  def resolver_filtros(props, valores_hermanos, campos_hermanos \\ []) do
    dependencias = props["dependencias"] || []

    Enum.reduce_while(dependencias, {:ok, %{}}, fn dep, {:ok, filtros} ->
      campo_padre = dep["campo_padre"]
      campo_remoto = dep["campo_remoto"]
      obligatorio? = dep["obligatorio"] != false
      valor_padre = valor_no_vacio(Map.get(valores_hermanos, campo_padre))

      cond do
        valor_padre != nil and campo_remoto not in [nil, ""] ->
          {:cont, {:ok, Map.put(filtros, campo_remoto, valor_padre)}}

        obligatorio? ->
          mensaje = props["mensaje_sin_padre"] || mensaje_sin_padre_por_defecto(campo_padre, campos_hermanos)
          {:halt, {:disabled, mensaje}}

        true ->
          {:cont, {:ok, filtros}}
      end
    end)
  end

  defp valor_no_vacio(nil), do: nil
  defp valor_no_vacio(""), do: nil
  defp valor_no_vacio(valor), do: valor

  defp mensaje_sin_padre_por_defecto(campo_padre, campos_hermanos) do
    etiqueta =
      case Enum.find(campos_hermanos, &(&1.schema_context_field == campo_padre)) do
        nil -> campo_padre
        detalle -> detalle.schema_context_properties["etiqueta"] || campo_padre
      end

    "Selecciona primero \"#{etiqueta}\""
  end

  @doc """
  Validación de INTEGRIDAD (no confiar en lo que mandó el navegador): por
  cada campo referencia de `catalogo` con `"dependencias"` que tenga
  valor en `changeset`, confirma que el registro destino realmente
  cumple `campo_remoto == valor_actual_del_padre` para cada dependencia
  — si no, agrega un error legible al campo. Corre en runtime (consulta
  `listar_detalles/1` fresco) porque la config de dependencias se guarda
  como cualquier otra propiedad de campo (`actualizar_detalle/2`, sin
  regenerar el schema) — `@campos_meta` del schema generado queda
  congelado en el momento de creación del catálogo y nunca la vería.
  Fail-safe ante datos mal formados (campo/catálogo destino inexistente,
  etc.): esos casos agregan error en vez de crashear el guardado.
  """
  def validar_dependencias_referencia(changeset, catalogo) do
    catalogo
    |> campos_con_dependencias()
    |> Enum.reduce(changeset, &validar_una_dependencia_referencia(&2, &1))
  end

  defp validar_una_dependencia_referencia(changeset, detalle) do
    campo = detalle.schema_context_field
    props = detalle.schema_context_properties
    campo_atom = String.to_existing_atom(campo)
    valor = Ecto.Changeset.get_field(changeset, campo_atom)

    if valor in [nil, ""] do
      changeset
    else
      Enum.reduce(props["dependencias"] || [], changeset, fn dep, cs ->
        validar_dependencia_contra_registro(cs, campo_atom, valor, props["catalogo"], dep)
      end)
    end
  end

  # Separa a propósito "no se pudo determinar" (metadata incompleta, padre
  # todavía sin valor, destino no encontrado — se ignora en silencio,
  # fail-safe) de "se determinó y NO coincide" (el único caso que agrega
  # error) — un `with`/`else` que colapsara ambos en el mismo valor
  # (ej. `false`) los confundiría y podría rechazar guardados válidos
  # solo porque la metadata está incompleta.
  defp validar_dependencia_contra_registro(changeset, campo_atom, valor_hijo, catalogo_destino, dep) do
    campo_padre = dep["campo_padre"]
    campo_remoto = dep["campo_remoto"]

    if es_texto_no_vacio?(campo_padre) and es_texto_no_vacio?(campo_remoto) do
      padre_atom = String.to_existing_atom(campo_padre)
      valor_padre = Ecto.Changeset.get_field(changeset, padre_atom)

      if valor_padre in [nil, ""] do
        changeset
      else
        case resolver_valor_remoto(catalogo_destino, valor_hijo, campo_remoto) do
          {:ok, valor_remoto} ->
            if to_string(valor_remoto) == to_string(valor_padre) do
              changeset
            else
              Ecto.Changeset.add_error(changeset, campo_atom, "el valor seleccionado no corresponde a la selección anterior")
            end

          :error ->
            changeset
        end
      end
    else
      changeset
    end
  rescue
    ArgumentError -> changeset
  end

  defp es_texto_no_vacio?(valor), do: is_binary(valor) and valor != ""

  defp resolver_valor_remoto(catalogo_destino, valor_hijo, campo_remoto) do
    # Gap conocido (Fase 5, no corregido acá) -- helper de DISPLAY (resuelve
    # el valor legible de un campo "referencia"), mismo criterio ya
    # aceptado para Formula/opciones_referencia en la Fase 4a: no
    # threadea Scope, marcado como mejora pendiente real.
    with modulo when not is_nil(modulo) <- modulo_por_nombre(catalogo_destino),
         id_hijo when not is_nil(id_hijo) <- a_entero_seguro(valor_hijo),
         # credo:disable-for-next-line MetadataApp.CredoChecks.RepoDirectoConVariable
         registro_destino when not is_nil(registro_destino) <- Repo.get(modulo, id_hijo),
         remoto_atom <- String.to_existing_atom(campo_remoto) do
      {:ok, Map.get(registro_destino, remoto_atom)}
    else
      _ -> :error
    end
  end

  defp a_entero_seguro(valor) when is_integer(valor), do: valor

  defp a_entero_seguro(valor) when is_binary(valor) do
    case Integer.parse(valor) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp a_entero_seguro(_valor), do: nil

  # --- Formato de captura (máscaras de texto, número/moneda) -----------------
  #
  # Un campo puede traer "formato_captura" en su schema_context_properties:
  # %{"habilitada" => bool, "modo" => "telefono"|"cp"|"rfc"|"fecha"|
  # "personalizada"|"numero"|"moneda", "patron" => "(999) 999-9999" (modos
  # posicionales, tipo "string" — A=letra, 9=número, *=cualquiera, el resto
  # literal), "guardar_formato" => bool (solo "string": persistir con o sin
  # los literales del patrón), "decimales"/"permitir_negativos" (modos
  # "numero"/"moneda", tipo "integer"/"decimal"), "permitir_incompleto",
  # "mensaje_invalido". Mismo criterio que "dependencias" arriba: metadata
  # libre en el mapa ya existente, sin migración, validada en runtime.

  @doc "Campos de `catalogo` con \"formato_captura\" habilitado."
  def campos_con_formato_captura(catalogo) do
    catalogo
    |> listar_detalles()
    |> Enum.filter(fn d -> get_in(d.schema_context_properties, ["formato_captura", "habilitada"]) == true end)
  end

  @doc """
  Validación de integridad del valor capturado contra la config de
  "formato_captura" de cada campo — corre en runtime (`listar_detalles/1`
  fresco), mismo motivo que `validar_dependencias_referencia/2`: la config
  se guarda vía `actualizar_detalle/2`, sin regenerar el schema, así que
  `@campos_meta` (congelado al crear el catálogo) nunca la vería.
  Fail-safe: metadata mal formada o campo sin valor no rompe, se salta.
  """
  def validar_formato_captura(changeset, catalogo) do
    catalogo
    |> campos_con_formato_captura()
    |> Enum.reduce(changeset, &validar_un_formato_captura(&2, &1))
  end

  defp validar_un_formato_captura(changeset, detalle) do
    props = detalle.schema_context_properties
    campo_atom = String.to_existing_atom(detalle.schema_context_field)
    valor = Ecto.Changeset.get_field(changeset, campo_atom)
    formato = props["formato_captura"]

    cond do
      valor in [nil, ""] -> changeset
      props["tipo"] == "string" and formato["modo"] in ["numero", "moneda"] -> validar_formato_numerico_texto(changeset, campo_atom, valor, formato)
      props["tipo"] == "string" -> validar_formato_texto(changeset, campo_atom, valor, formato)
      props["tipo"] in ["integer", "decimal"] -> validar_formato_numerico(changeset, campo_atom, valor, formato)
      true -> changeset
    end
  rescue
    ArgumentError -> changeset
  end

  # Compara `valor` contra el patrón completo (nunca contra un regex
  # ingenuo `patron == valor`, porque distingue "con formato" de "solo
  # datos" — ver `guardar_formato`) construyendo, char a char, una
  # alternativa regex "anidada-opcional" cuando `permitir_incompleto` está
  # activo: cada token es seguido por el resto del patrón envuelto en un
  # grupo opcional, así el valor puede cortar en cualquier borde de token
  # (nunca a mitad de una clase) sin tener que reimplementar el motor de
  # máscara del cliente acá.
  defp validar_formato_texto(changeset, campo_atom, valor, formato) do
    patron = formato["patron"]

    if es_texto_no_vacio?(patron) do
      tokens =
        if formato["guardar_formato"] == false,
          do: patron_tokens_solo_datos(patron),
          else: patron_tokens(patron)

      regex =
        if formato["permitir_incompleto"] == true,
          do: patron_regex_incompleto(tokens),
          else: patron_regex_completo(tokens)

      if Regex.match?(regex, valor) do
        changeset
      else
        Ecto.Changeset.add_error(changeset, campo_atom, mensaje_formato_invalido(formato))
      end
    else
      changeset
    end
  end

  defp patron_tokens(patron) do
    patron
    |> String.graphemes()
    |> Enum.map(fn
      "A" -> "[A-Za-z]"
      "9" -> "[0-9]"
      "*" -> "."
      c -> Regex.escape(c)
    end)
  end

  defp patron_tokens_solo_datos(patron) do
    patron
    |> String.graphemes()
    |> Enum.filter(&(&1 in ["A", "9", "*"]))
    |> Enum.map(fn
      "A" -> "[A-Za-z]"
      "9" -> "[0-9]"
      "*" -> "."
    end)
  end

  defp patron_regex_completo(tokens), do: Regex.compile!("^" <> Enum.join(tokens) <> "$")

  defp patron_regex_incompleto(tokens), do: Regex.compile!("^" <> construir_incompleto(tokens) <> "$")

  defp construir_incompleto([]), do: ""
  defp construir_incompleto([t | resto]), do: t <> "(?:" <> construir_incompleto(resto) <> ")?"

  # "Número"/"Moneda" en un campo tipo "string" (a diferencia de
  # validar_formato_numerico/4 más abajo, que valida un %Decimal{}/integer
  # YA tipado de una columna numérica real): acá `valor` es texto crudo
  # ("1234.50" o, con guardar_formato, "$1,234.50"), así que se valida
  # entero con UN regex — separadores de miles y símbolo solo se admiten
  # cuando `guardar_formato` está activo, igual que ese mismo interruptor
  # decide si un campo posicional persiste sus literales o no.
  defp validar_formato_numerico_texto(changeset, campo_atom, valor, formato) do
    if Regex.match?(regex_numero_texto(formato), valor) do
      changeset
    else
      Ecto.Changeset.add_error(changeset, campo_atom, mensaje_formato_invalido(formato))
    end
  end

  defp regex_numero_texto(formato) do
    decimales = if is_integer(formato["decimales"]), do: formato["decimales"], else: 0
    con_formato? = formato["guardar_formato"] == true

    signo = if formato["permitir_negativos"] == true, do: "-?", else: ""
    parte_decimal = if decimales > 0, do: "(?:\\.\\d{1,#{decimales}})?", else: ""

    parte_entera =
      if con_formato? and formato["separador_miles"] == true,
        do: "(?:\\d{1,3}(?:,\\d{3})*|\\d+)",
        else: "\\d+"

    cuerpo = signo <> parte_entera <> parte_decimal

    cuerpo =
      if con_formato? and formato["modo"] == "moneda" and es_texto_no_vacio?(formato["simbolo"]) do
        simbolo = Regex.escape(formato["simbolo"])
        if formato["simbolo_posicion"] == "sufijo", do: cuerpo <> " ?" <> simbolo, else: simbolo <> cuerpo
      else
        cuerpo
      end

    Regex.compile!("^" <> cuerpo <> "$")
  end

  defp validar_formato_numerico(changeset, campo_atom, valor, formato) do
    decimales = formato["decimales"]
    permitir_negativos? = formato["permitir_negativos"] == true

    cond do
      is_integer(decimales) and excede_decimales?(valor, decimales) ->
        Ecto.Changeset.add_error(changeset, campo_atom, mensaje_formato_invalido(formato, "no puede tener más de #{decimales} decimales"))

      not permitir_negativos? and negativo?(valor) ->
        Ecto.Changeset.add_error(changeset, campo_atom, mensaje_formato_invalido(formato, "no puede ser negativo"))

      true ->
        changeset
    end
  end

  defp excede_decimales?(%Decimal{} = valor, decimales), do: Decimal.scale(valor) > decimales
  defp excede_decimales?(_valor, _decimales), do: false

  defp negativo?(%Decimal{} = valor), do: Decimal.negative?(valor)
  defp negativo?(valor) when is_integer(valor), do: valor < 0
  defp negativo?(_valor), do: false

  defp mensaje_formato_invalido(formato, default \\ "no tiene el formato esperado") do
    case formato["mensaje_invalido"] do
      msg when is_binary(msg) and msg != "" -> msg
      _ -> default
    end
  end

  @doc """
  A partir de una lista de catálogos raíz, calcula el paquete completo a
  publicar: agrega los detalles de cada maestro, el cierre transitivo de
  todo campo tipo "referencia" (si A referencia a B y B referencia a C,
  publicar A tiene que arrastrar también a B y C, o su migración crea una
  FK contra una tabla que en producción todavía no existe), y devuelve el
  resultado en orden topológico (ver ordenar_por_dependencias/1).

  Único lugar donde se calcula esto — antes `mix motor.publicar` tenía su
  propia copia de la expansión de referencias y `mix gen.catalogos` la
  suya del orden topológico; las dos formas de armar un paquete podían
  desincronizarse con el tiempo. Pensado para que el wizard de
  publicación (selección de varios BC a la vez) también lo use.
  """
  def calcular_paquete_publicacion(nombres_raiz) when is_list(nombres_raiz) do
    con_detalles =
      nombres_raiz
      |> Enum.flat_map(&[&1 | detalles_de_catalogo(&1)])
      |> Enum.uniq()

    con_detalles
    |> expandir_referencias(MapSet.new(con_detalles))
    |> ordenar_por_dependencias()
  end

  defp detalles_de_catalogo(nombre) do
    case obtener_header_por_nombre(nombre) do
      nil -> []
      header -> header.id |> listar_catalogos_detalle() |> Enum.map(& &1.schema_context_name)
    end
  end

  defp expandir_referencias(pendientes, vistos) do
    detalles_por_catalogo = listar_detalles_de_varios(pendientes)

    nuevos =
      pendientes
      |> Enum.flat_map(&referencias_de(&1, detalles_por_catalogo))
      |> Enum.uniq()
      |> Enum.reject(&MapSet.member?(vistos, &1))

    case nuevos do
      [] -> MapSet.to_list(vistos)
      _ -> expandir_referencias(nuevos, Enum.reduce(nuevos, vistos, &MapSet.put(&2, &1)))
    end
  end

  defp referencias_de(catalogo, detalles_por_catalogo) do
    detalles_por_catalogo
    |> Map.get(catalogo, [])
    |> Enum.filter(&(&1.schema_context_properties["tipo"] == "referencia"))
    |> Enum.map(& &1.schema_context_properties["catalogo"])
  end

  @doc """
  Orden topológico (Kahn) sobre la relación "campo tipo referencia ->
  catálogo": un catálogo se coloca después de todo lo que referencia. Sirve
  tanto para TODOS los headers (`mix gen.catalogos`) como para un
  subconjunto ya cerrado por dependencias (`calcular_paquete_publicacion/1`)
  — las dependencias fuera de la lista dada simplemente se ignoran. Aborta
  con excepción si queda un ciclo sin poder resolverse dentro del lote.
  """
  def ordenar_por_dependencias(nombres) do
    nombres_set = MapSet.new(nombres)
    detalles_por_catalogo = listar_detalles_de_varios(nombres)

    dependencias =
      Map.new(nombres, fn nombre ->
        deps =
          detalles_por_catalogo
          |> Map.get(nombre, [])
          |> Enum.filter(&(Map.get(&1.schema_context_properties || %{}, "tipo") == "referencia"))
          |> Enum.map(&Map.fetch!(&1.schema_context_properties, "catalogo"))
          |> Enum.filter(&MapSet.member?(nombres_set, &1))
          |> Enum.uniq()

        {nombre, deps}
      end)

    ordenar_topologico(dependencias, [])
  end

  defp ordenar_topologico(pendientes, hechos) when map_size(pendientes) == 0, do: Enum.reverse(hechos)

  defp ordenar_topologico(pendientes, hechos) do
    hechos_set = MapSet.new(hechos)

    {listos, resto} =
      Enum.split_with(pendientes, fn {_nombre, deps} ->
        Enum.all?(deps, &MapSet.member?(hechos_set, &1))
      end)

    case listos do
      [] ->
        raise "Dependencia circular entre catálogos, no se puede determinar un orden: #{inspect(Map.keys(pendientes))}"

      _ ->
        nombres_listos = Enum.map(listos, fn {nombre, _deps} -> nombre end)
        ordenar_topologico(Map.new(resto), Enum.reverse(nombres_listos) ++ hechos)
    end
  end

  # Crea el Header y todos sus Detalles en una sola transacción: todo o nada.
  def crear_header_con_detalles(%{"detalles" => detalles} = header_attrs) when is_list(detalles) do
    Repo.transaction(fn ->
      header_attrs = Map.drop(header_attrs, ["detalles"])

      header =
        %Header{}
        |> Header.changeset(header_attrs)
        |> Ecto.Changeset.change(%{insert_guid: generar_guid()})
        |> Repo.insert()
        |> case do
          {:ok, header} -> header
          {:error, changeset} -> Repo.rollback(changeset)
        end

      detalles_creados =
        Enum.map(detalles, fn detalle_attrs ->
          attrs = Map.put(detalle_attrs, "meta_schema_header_id", header.id)

          %Detail{}
          |> Detail.changeset(attrs)
          |> validar_campos_acompanamiento()
          |> validar_campo_visualizacion()
          |> Ecto.Changeset.change(%{insert_guid: generar_guid()})
          |> Repo.insert()
          |> case do
            {:ok, detalle} -> detalle
            {:error, changeset} -> Repo.rollback(changeset)
          end
        end)

      {header, detalles_creados}
    end)
  end

  # Agrega UN campo a un catálogo que ya existe (a diferencia de
  # crear_header_con_detalles/1, que crea el header y todos sus detalles
  # juntos al nacer) — CatalogoGenerador.generar/1 hay que volver a
  # correrlo después de esto para que la columna física se agregue de
  # verdad (asegurar_campos_nuevos/1 ya lo hace solo si el schema existe).
  def agregar_detalle(%Header{} = header, attrs) do
    attrs = Map.put(attrs, "meta_schema_header_id", header.id)

    %Detail{}
    |> Detail.changeset(attrs)
    |> validar_campos_acompanamiento()
    |> validar_campo_visualizacion()
    |> Ecto.Changeset.change(%{insert_guid: generar_guid()})
    |> Repo.insert()
  end

  # Edita las propiedades de un campo que ya existe (a diferencia de
  # agregar_detalle/2, que crea uno nuevo) — usado por el panel
  # "Relaciones" para configurar "campos_acompanamiento" en un campo tipo
  # "referencia" ya creado. No toca la columna física: eso solo aplica a
  # campos nuevos o borrados (ver CatalogoGenerador), acá solo cambia
  # metadata.
  def actualizar_detalle(%Detail{} = detalle, attrs) do
    detalle
    |> Detail.changeset(attrs)
    |> validar_campos_acompanamiento()
    |> validar_campo_visualizacion()
    |> Ecto.Changeset.change(%{update_guid: generar_guid()})
    |> Repo.update()
  end

  # Si el detalle es un campo tipo "referencia" con "campos_acompanamiento"
  # configurado, cada uno de esos campos tiene que existir de verdad en el
  # catálogo DESTINO (el referenciado) — solo una validación de existencia,
  # no una whitelist de "exportables" (se consideró esa opción y se
  # descartó: agregaba un paso extra sin pedirse). Ver
  # docs/roadmap-campos-acompanamiento.md.
  defp validar_campos_acompanamiento(changeset) do
    case Ecto.Changeset.get_field(changeset, :schema_context_properties) do
      %{"tipo" => "referencia", "catalogo" => catalogo, "campos_acompanamiento" => campos}
      when is_list(campos) and campos != [] ->
        campos_reales = catalogo |> listar_detalles() |> Enum.map(& &1.schema_context_field)

        case campos -- campos_reales do
          [] ->
            changeset

          inexistentes ->
            Ecto.Changeset.add_error(
              changeset,
              :schema_context_properties,
              "campo(s) inexistente(s) en #{catalogo}: #{Enum.join(inexistentes, ", ")}"
            )
        end

      _ ->
        changeset
    end
  end

  # "Configuración de visualización" de un campo tipo "referencia" —
  # separa el VALOR guardado (siempre el id físico del registro destino,
  # nunca configurable — ver campo_visualizacion abajo) del TEXTO que se
  # muestra en el picker/lectura (CatalogoGenerico.opciones_referencia/1).
  # Reemplaza en los hechos a "campos_acompanamiento" (que sigue existiendo
  # tal cual, sin tocar, para el enriquecido del GET/tabla — ver
  # docs/roadmap-campos-acompanamiento.md) cuando está configurado; si no
  # está, opciones_referencia/1 sigue cayendo al join de siempre.
  #
  # Forma esperada de "campo_visualizacion":
  #   %{"modo" => "descripcion", "campo_descripcion" => "..."}
  #   %{"modo" => "codigo_descripcion", "campo_codigo" => "...", "campo_descripcion" => "..."}
  #   %{"modo" => "plantilla", "plantilla" => "{campo_a} - {campo_b}"}
  #   %{"modo" => "calculado", "formula" => "IF {a} > {b} THEN \"X\" ELSE \"Y\""}
  defp validar_campo_visualizacion(changeset) do
    case Ecto.Changeset.get_field(changeset, :schema_context_properties) do
      %{"tipo" => "referencia", "catalogo" => catalogo, "campo_visualizacion" => %{} = config} ->
        campos_reales = catalogo |> listar_detalles() |> Enum.map(& &1.schema_context_field)

        case validar_config_visualizacion(config, campos_reales) do
          :ok -> changeset
          {:error, motivo} -> Ecto.Changeset.add_error(changeset, :schema_context_properties, motivo)
        end

      _ ->
        changeset
    end
  end

  defp validar_config_visualizacion(%{"modo" => "descripcion"} = config, campos_reales),
    do: validar_campo_existente(config["campo_descripcion"], "campo de descripción", campos_reales)

  defp validar_config_visualizacion(%{"modo" => "codigo_descripcion"} = config, campos_reales) do
    with :ok <- validar_campo_existente(config["campo_codigo"], "campo de código", campos_reales) do
      validar_campo_existente(config["campo_descripcion"], "campo de descripción", campos_reales)
    end
  end

  defp validar_config_visualizacion(%{"modo" => "plantilla"} = config, campos_reales) do
    with :ok <- validar_texto_no_vacio(config["plantilla"], "la plantilla de visualización") do
      validar_variables_presentes(config["plantilla"], campos_reales)
    end
  end

  defp validar_config_visualizacion(%{"modo" => "calculado"} = config, campos_reales) do
    with :ok <- validar_texto_no_vacio(config["formula"], "la fórmula") do
      validar_variables_presentes(config["formula"], campos_reales)
    end
  end

  defp validar_config_visualizacion(_config, _campos_reales), do: {:error, "elegí un campo de visualización"}

  defp validar_campo_existente(campo, etiqueta, campos_reales) do
    cond do
      campo in [nil, ""] -> {:error, "elegí #{etiqueta}"}
      campo not in campos_reales -> {:error, "#{etiqueta} inexistente: #{campo}"}
      true -> :ok
    end
  end

  defp validar_texto_no_vacio(texto, etiqueta) do
    if texto in [nil, ""], do: {:error, "completá #{etiqueta}"}, else: :ok
  end

  # Solo valida referencias simples "{campo}" contra los campos reales del
  # catálogo destino — una fórmula en modo "calculado" también puede usar
  # "{catalogo#id.campo}"/"SUM(catalogo.campo)" (ver Formula), sintaxis que
  # a propósito no se valida acá (necesitaría resolver OTRO catálogo/id,
  # fuera de lo que esta pantalla conoce) — Formula.evaluar/2 ya es
  # fail-open ante esas fallas en tiempo de evaluación.
  defp validar_variables_presentes(texto, campos_reales) do
    variables = ~r/\{(\w+)\}/ |> Regex.scan(texto) |> Enum.map(&Enum.at(&1, 1)) |> Enum.uniq()

    case variables -- campos_reales do
      [] -> :ok
      inexistentes -> {:error, "variable(s) inexistente(s) en el catálogo destino: #{Enum.join(inexistentes, ", ")}"}
    end
  end

  # Soft-delete de un campo — la columna física NO se toca acá (ver
  # CatalogoGenerador.eliminar_campo/3, que orquesta esto + el DROP COLUMN +
  # regenerar el schema, en ese orden).
  def eliminar_detalle(%Detail{} = detalle) do
    detalle
    |> Ecto.Changeset.change(%{delete_guid: generar_guid()})
    |> Repo.update()
  end

  # Exporta ESTE header a <dir>/<catalogo>.meta.json — compartido entre
  # `mix meta.export` (recorre todos) y el botón "Guardar BC" de
  # BcMotorLive (uno solo). Vive acá y no en el Mix.Task porque un
  # Mix.Task no está pensado para invocarse desde un proceso de la app ya
  # corriendo (mismo motivo que MetaEstadosAdmin.andamiar_regla_negocio/3).
  def exportar_header(%Header{} = header, dir \\ "priv/repo/catalogos") do
    File.mkdir_p!(dir)
    detalles = listar_detalles(header.schema_context_name)

    contenido =
      Jason.encode!(
        %{
          schema_context_name: header.schema_context_name,
          schema_context_label: header.schema_context_label,
          schema_context_type: header.schema_context_type,
          schema_context_nav: header.schema_context_nav,
          schema_context_icono: header.schema_context_icono,
          schema_visible: header.schema_visible,
          schema_set_permissions: header.schema_set_permissions,
          schema_profiles: header.schema_profiles,
          cargar_todos_por_default: header.cargar_todos_por_default,
          mostrar_id_en_tabla: header.mostrar_id_en_tabla,
          mostrar_estado_en_tabla: header.mostrar_estado_en_tabla,
          mostrar_trn_en_tabla: header.mostrar_trn_en_tabla,
          schema_es_transaccional: header.schema_es_transaccional,
          codigo_trn: header.codigo_trn,
          schema_encabezado_catalogo: nombre_encabezado(header.schema_encabezado_id),
          detalles: Enum.map(detalles, &serializar_detalle/1)
        },
        pretty: true
      )

    File.write!(Path.join(dir, "#{header.schema_context_name}.meta.json"), contenido)
    header.schema_context_name
  end

  # schema_encabezado_id es un id crudo (FK a otro meta_schema_header.id) --
  # no sirve para exportar/importar entre ambientes distintos, donde los ids
  # no coinciden (bug real: un detalle desplegado a producción vía
  # motor.publicar quedaba con schema_encabezado_id nil porque el export
  # nunca lo mandaba, y el maestro/detalle se rompía en runtime con "no es
  # un catálogo detalle de este maestro"). Se exporta por NOMBRE, igual que
  # estados/transiciones en motor.export, y se resuelve a id en el import.
  defp nombre_encabezado(nil), do: nil
  defp nombre_encabezado(id), do: Repo.get(Header, id).schema_context_name

  def actualizar_header(%Header{} = header, attrs) do
    header
    |> Header.changeset(attrs)
    |> Ecto.Changeset.change(%{update_guid: generar_guid()})
    |> Repo.update()
  end

  @doc """
  Persiste el orden manual (drag-and-drop, "Editar vista" en BcListLive)
  de una lista de CLAVES que son HERMANAS entre sí — el índice de cada
  una en `claves` se guarda como su `orden`. Sirve tanto para las
  carpetas raíz como para los hijos de CUALQUIER carpeta (carpetas y
  catálogos mezclados) — el "orden" solo se compara contra hermanos del
  mismo nivel del árbol (ver `clave_orden/1`), así que da lo mismo si
  distintos grupos de hermanos reusan los mismos números 0..N-1 entre sí.

  Cada clave es una de dos cosas (ver `clave_de_carpeta/2` en
  BcListLive, mismo criterio en los dos lados):
    - un `schema_context_name` real (catálogo, o carpeta con Header
      propio) — se persiste en la columna `orden` de `meta_schema_header`.
    - `"ruta:" <> ruta_acumulada` — una carpeta IMPLÍCITA (sin Header
      propio, inferida solo de la ruta de lo que tiene adentro), donde no
      hay fila de Header en la que guardar nada — se persiste por ruta en
      `meta_schema_carpeta_orden` (ver `MetaSchema.CarpetaOrden`).

  `Repo.update_all/2` en vez de un changeset por fila: es un solo campo
  sin validaciones que respetar, y son pocas filas a la vez, no vale la
  pena el round-trip de traer cada Header primero.

  Descarta cualquier `nil` en `claves` a propósito, para que esta función
  sea segura de usar sola sin depender de que el caller filtre primero.
  """
  # Un solo drag-and-drop reordena hasta @por_pagina hermanos a la vez —
  # antes esto era un insert/update_all POR hermano (hasta 30 queries por
  # movimiento). Acá: un único insert_all (upsert por :ruta, on_conflict
  # reemplaza solo :orden) para las carpetas implícitas, y un único UPDATE
  # parametrizado con unnest (per-row, sin CASE dinámico armado a mano —
  # nada de interpolar valores del cliente en el SQL) para los catálogos
  # reales.
  def reordenar_hermanos(claves) do
    {rutas, nombres} =
      claves
      |> Enum.reject(&is_nil/1)
      |> Enum.with_index()
      |> Enum.split_with(fn {clave, _indice} -> match?("ruta:" <> _resto, clave) end)

    if rutas != [] do
      entradas = Enum.map(rutas, fn {"ruta:" <> ruta, indice} -> %{ruta: ruta, orden: indice} end)
      Repo.insert_all(CarpetaOrden, entradas, on_conflict: {:replace, [:orden]}, conflict_target: :ruta)
    end

    if nombres != [] do
      Repo.query!(
        """
        UPDATE meta_schema_header AS h SET orden = data.orden
        FROM (SELECT unnest($1::text[]) AS schema_context_name, unnest($2::int[]) AS orden) AS data
        WHERE h.schema_context_name = data.schema_context_name
        """,
        [Enum.map(nombres, &elem(&1, 0)), Enum.map(nombres, &elem(&1, 1))]
      )
    end

    :ok
  end

  # Reordenar los CAMPOS (meta_schema_detail) de un catálogo -- no confundir
  # con reordenar_hermanos/1 de arriba (esa es para Headers/carpetas del
  # árbol de navegación). "orden" acá vive adentro del JSONB
  # schema_context_properties, no en una columna propia, por eso
  # jsonb_set en vez del UPDATE simple de reordenar_hermanos/1. A
  # propósito NO dispara CatalogoGenerador.generar/1 -- el orden es
  # puramente de presentación (tabla de Campos, orden del form de Alta,
  # PostView automático), no afecta el schema Ecto compilado ni requiere
  # ningún ALTER en la tabla física.
  def reordenar_campos(header_id, campos_en_orden) do
    Repo.query!(
      """
      UPDATE meta_schema_detail AS d
      SET schema_context_properties = jsonb_set(d.schema_context_properties, '{orden}', to_jsonb(data.orden))
      FROM (SELECT unnest($1::text[]) AS schema_context_field, unnest($2::int[]) AS orden) AS data
      WHERE d.schema_context_field = data.schema_context_field AND d.meta_schema_header_id = $3
      """,
      [campos_en_orden, Enum.to_list(0..(length(campos_en_orden) - 1)), header_id]
    )

    :ok
  end

  # Borrado total (no soft-delete): al ser el Header dueño de la definición
  # del catálogo, borrarlo se lleva en cascada (on_delete: :delete_all) sus
  # Detalles y, si el catálogo adoptó el motor de estados, también Estados/
  # Transiciones/Reglas — un Detalle o Estado sin Header no tiene sentido.
  # Propaga el resultado (antes se descartaba con Repo.delete/1 + :ok fijo,
  # así que un fallo de FK real quedaba como excepción sin capturar en vez
  # de un {:error, _} manejable).
  def eliminar_header(%Header{} = header) do
    case Repo.delete(header) do
      {:ok, _header} -> :ok
      {:error, changeset} -> {:error, changeset}
    end
  end

  def serializar_detalle(%Detail{} = detalle) do
    %{
      schema_context_field: detalle.schema_context_field,
      schema_context_properties: detalle.schema_context_properties
    }
  end

  defp generar_guid do
    Ecto.UUID.generate() |> String.replace("-", "")
  end
end
