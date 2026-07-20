defmodule MetadataApp.BusinessProcessBuilder.MetaSchemaContext do
  alias MetadataApp.Repo
  alias MetadataApp.BusinessProcessBuilder.MetaSchema.Header
  alias MetadataApp.BusinessProcessBuilder.MetaSchema.Detail
  import Ecto.Query

  # order_by explícito a propósito: sin esto Postgres no garantiza el orden
  # de las filas devueltas, y mix meta.export terminaba produciendo diffs
  # sin sentido (el archivo entero "cambiaba" de orden) sin ningún cambio
  # real en la base.
  def listar_headers do
    from(h in Header, where: is_nil(h.delete_guid), order_by: h.schema_context_name)
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

  def item_de_header(h) do
    %{
      id: h.schema_context_name,
      label: h.schema_context_label,
      nav: h.schema_context_nav,
      visible: h.schema_visible,
      icono: h.schema_context_icono,
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
        insertar_carpeta_explicita(arbol, segmentos(item.nav), item.label, item[:icono], item.id)
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
    nodo_default = %{nombre: nil, icono: nil, id: nil, hijos: insertar_en_arbol(%{}, resto, item)}

    Map.update(mapa, {:carpeta, carpeta}, nodo_default, fn nodo ->
      %{nodo | hijos: insertar_en_arbol(nodo.hijos, resto, item)}
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
  defp insertar_carpeta_explicita(mapa, [], _label, _icono, _id), do: mapa

  defp insertar_carpeta_explicita(mapa, [ultimo], label, icono, id) do
    # Map.merge en vez de %{nodo | ...}: si esta carpeta ya existía en el
    # mapa como nodo "inferido" (creado por insertar_en_arbol/3 al procesar
    # una página hija que se coló primero en el Enum.reduce — el orden
    # depende del orden alfabético de schema_context_name, no del nav), ese
    # nodo no tiene las claves :icono/:id todavía. %{nodo | ...} exige que
    # ya existan (KeyError si no) — Map.merge las agrega sin problema.
    Map.update(mapa, {:carpeta, ultimo}, %{nombre: label, icono: icono, id: id, hijos: %{}}, fn nodo ->
      Map.merge(nodo, %{nombre: label, icono: icono, id: id})
    end)
  end

  defp insertar_carpeta_explicita(mapa, [seg | resto], label, icono, id) do
    nodo_default = %{
      nombre: nil,
      icono: nil,
      id: nil,
      hijos: insertar_carpeta_explicita(%{}, resto, label, icono, id)
    }

    Map.update(mapa, {:carpeta, seg}, nodo_default, fn nodo ->
      %{nodo | hijos: insertar_carpeta_explicita(nodo.hijos, resto, label, icono, id)}
    end)
  end

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
          hijos: mapa_a_lista_ordenada(nodo.hijos)
        }
    end)
    |> Enum.sort_by(fn
      %{tipo: :carpeta, nombre: nombre} -> {0, nombre}
      %{tipo: :pagina, label: label} -> {1, label}
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

  # schema_context_name cubre hoy el rol que antes cumplían schema_nombre y
  # tabla por separado: identifica el catálogo y es el nombre físico de la
  # tabla de Postgres.
  def obtener_header_por_nombre(schema_context_name) do
    Repo.one(
      from h in Header, where: h.schema_context_name == ^schema_context_name and is_nil(h.delete_guid)
    )
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

  # Agrega UN campo a un catálogo que ya existe (a diferencia de
  # crear_header_con_detalles/1, que crea el header y todos sus detalles
  # juntos al nacer) — CatalogoGenerador.generar/1 hay que volver a
  # correrlo después de esto para que la columna física se agregue de
  # verdad (asegurar_campos_nuevos/1 ya lo hace solo si el schema existe).
  def agregar_detalle(%Header{} = header, attrs) do
    attrs = Map.put(attrs, "meta_schema_header_id", header.id)

    %Detail{}
    |> Detail.changeset(attrs)
    |> Ecto.Changeset.change(%{insert_guid: generar_guid()})
    |> Repo.insert()
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
          schema_visible: header.schema_visible,
          schema_set_permissions: header.schema_set_permissions,
          schema_profiles: header.schema_profiles,
          detalles: Enum.map(detalles, &serializar_detalle/1)
        },
        pretty: true
      )

    File.write!(Path.join(dir, "#{header.schema_context_name}.meta.json"), contenido)
    header.schema_context_name
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
