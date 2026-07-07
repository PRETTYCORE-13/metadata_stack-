defmodule MetadataApp.MetaSchemaContext do
  alias MetadataApp.Repo
  alias MetadataApp.MetaSchema.Header
  alias MetadataApp.MetaSchema.Detail
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
    |> Enum.map(fn h ->
      %{id: h.schema_context_name, label: h.schema_context_label, nav: h.schema_context_nav}
    end)
    |> Enum.reduce(%{}, fn item, arbol ->
      segmentos = item.nav |> String.trim_leading("/") |> String.split("/", trim: true)
      insertar_en_arbol(arbol, segmentos, item)
    end)
    |> mapa_a_lista_ordenada()
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
    Map.update(mapa, {:carpeta, carpeta}, insertar_en_arbol(%{}, resto, item), fn hijos ->
      insertar_en_arbol(hijos, resto, item)
    end)
  end

  defp mapa_a_lista_ordenada(mapa) do
    mapa
    |> Enum.map(fn
      {{:pagina, _clave}, item} -> %{tipo: :pagina, id: item.id, label: item.label, nav: item.nav}
      {{:carpeta, nombre}, hijos} -> %{tipo: :carpeta, nombre: nombre, hijos: mapa_a_lista_ordenada(hijos)}
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

  # Resuelve el módulo Ecto (ej. MetadataApp.Catalogos.PtyMoto) a partir del
  # nombre — se deriva en el momento, no se guarda: es determinista.
  def modulo_por_nombre(schema_context_name) do
    with %Header{} <- obtener_header_por_nombre(schema_context_name),
         modulo <- Module.concat(MetadataApp.Catalogos, Macro.camelize(schema_context_name)),
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
  # del catálogo, borrarlo se lleva sus Detalles en cascada (on_delete:
  # :delete_all en la FK) — un Detalle sin Header no tiene sentido.
  def eliminar_header(%Header{} = header) do
    Repo.delete(header)
    :ok
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
