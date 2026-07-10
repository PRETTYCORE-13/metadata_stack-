defmodule MetadataApp.BusinessProcessBuilder.MetaSchemaContext do
  alias MetadataApp.Repo
  alias MetadataApp.BusinessProcessBuilder.MetaSchema.Header
  alias MetadataApp.BusinessProcessBuilder.MetaSchema.Detail
  import Ecto.Query

  def listar_headers do
    from(h in Header, where: is_nil(h.delete_guid))
    |> Repo.all()
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

  defp item_de_header(h) do
    %{
      id: h.schema_context_name,
      label: h.schema_context_label,
      nav: h.schema_context_nav,
      visible: h.schema_visible,
      es_carpeta: h.schema_context_type == 2
    }
  end

  # Recibe una lista de %{id:, label:, nav:, es_carpeta:, ...} y arma el
  # árbol de carpetas/páginas a partir del nav de cada uno. Cualquier llave
  # extra en el item (ej. :visible) sobrevive en el nodo de página
  # resultante. Un item con es_carpeta: true no genera página — solo declara
  # (o le pone nombre bonito a) la carpeta en esa ruta.
  def construir_arbol(items) do
    items
    |> Enum.reduce(%{}, fn item, arbol ->
      if item.es_carpeta do
        insertar_carpeta_explicita(arbol, segmentos(item.nav), item.label)
      else
        insertar_en_arbol(arbol, segmentos_con_carpeta(item), item)
      end
    end)
    |> mapa_a_lista_ordenada()
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

  defp insertar_en_arbol(mapa, [ultimo], item) do
    Map.put(mapa, {:pagina, ultimo}, item)
  end

  defp insertar_en_arbol(mapa, [], item) do
    # nav sin segmentos (ej. "/") — no debería pasar con la validación
    # actual, pero por si acaso no se pierde el ítem.
    Map.put(mapa, {:pagina, item.id}, item)
  end

  defp insertar_en_arbol(mapa, [carpeta | resto], item) do
    nodo_default = %{nombre: nil, hijos: insertar_en_arbol(%{}, resto, item)}

    Map.update(mapa, {:carpeta, carpeta}, nodo_default, fn nodo ->
      %{nodo | hijos: insertar_en_arbol(nodo.hijos, resto, item)}
    end)
  end

  # Una carpeta explícita (registro tipo :carpeta) recorre/crea cada nivel
  # de su nav igual que insertar_en_arbol/3, pero en el nivel final no deja
  # una página — le pone su propio label como nombre "bonito" de esa
  # carpeta, en vez del segmento crudo de la URL.
  defp insertar_carpeta_explicita(mapa, [], _label), do: mapa

  defp insertar_carpeta_explicita(mapa, [ultimo], label) do
    Map.update(mapa, {:carpeta, ultimo}, %{nombre: label, hijos: %{}}, fn nodo ->
      %{nodo | nombre: label}
    end)
  end

  defp insertar_carpeta_explicita(mapa, [seg | resto], label) do
    nodo_default = %{nombre: nil, hijos: insertar_carpeta_explicita(%{}, resto, label)}

    Map.update(mapa, {:carpeta, seg}, nodo_default, fn nodo ->
      %{nodo | hijos: insertar_carpeta_explicita(nodo.hijos, resto, label)}
    end)
  end

  defp mapa_a_lista_ordenada(mapa) do
    mapa
    |> Enum.map(fn
      {{:pagina, _clave}, item} ->
        Map.put(item, :tipo, :pagina)

      {{:carpeta, segmento}, %{nombre: nombre, hijos: hijos}} ->
        %{tipo: :carpeta, nombre: nombre || segmento, hijos: mapa_a_lista_ordenada(hijos)}
    end)
    |> Enum.sort_by(fn
      %{tipo: :carpeta, nombre: nombre} -> {0, nombre}
      %{tipo: :pagina, label: label} -> {1, label}
    end)
  end

  def obtener_header!(id), do: Repo.get!(Header, id)

  # schema_context_name cubre hoy el rol que antes cumplían schema_nombre y
  # tabla por separado: identifica el catálogo y es el nombre físico de la
  # tabla de Postgres.
  def obtener_header_por_nombre(schema_context_name) do
    Repo.one(
      from h in Header, where: h.schema_context_name == ^schema_context_name and is_nil(h.delete_guid)
    )
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

  def listar_detalles(schema_context_name) do
    from(d in Detail,
      join: h in assoc(d, :header),
      where: h.schema_context_name == ^schema_context_name,
      where: is_nil(d.delete_guid),
      where: is_nil(h.delete_guid),
      order_by: [asc: fragment("(?->>'orden')::integer", d.schema_context_properties)]
    )
    |> Repo.all()
  end

  # schema_context_name de todo catálogo que tenga un detalle tipo
  # "referencia" apuntando a schema_context_name — bloquean su borrado total.
  def listar_dependientes(schema_context_name) do
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

  def actualizar_header(%Header{} = header, attrs) do
    header
    |> Header.changeset(attrs)
    |> Ecto.Changeset.change(%{update_guid: generar_guid()})
    |> Repo.update()
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
