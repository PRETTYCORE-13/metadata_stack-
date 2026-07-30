defmodule MetadataApp.MetaPlantillas do
  @moduledoc """
  Constructor de plantillas (MVP): CRUD de `MetaSchema.Plantilla` +
  manipulación pura del árbol de componentes que vive en `definicion`.

  Forma de `definicion`: `%{"tipo" => "raiz", "hijos" => [nodo, ...]}`, cada
  nodo `%{"id" => string, "tipo" => "seccion" | "fila" | "columna" | "panel"
  | "pestanas" | "pestana" | "campo" | "campo_calculado" | "autocompletar"
  | "divisor" | "tabla" | "etiqueta" | "alerta" | "tarjeta", "propiedades" => map,
  "hijos" => [nodo, ...]}` — solo los contenedores (`tipos_contenedor/0`)
  usan `hijos` de verdad, en el resto queda `[]` y no rompe nada recorrerlo
  igual.

  Un nodo "campo" SIEMPRE se resuelve en runtime contra el tipo real del
  campo elegido (`meta_schema_detail`, vía `campo_input/1` — ver
  `FichaLive.nodo_plantilla/1`) — nunca inventa un tipo propio. La
  propiedad `"tipo_filtro"` de un nodo "campo" es solo una ayuda del
  Constructor (acota el `<select>` de "qué campo mostrar" a los que
  calzan con el botón de paleta que se usó, ej. "Fecha" solo ofrece
  campos `tipo: "date"`) — no participa del renderizado real.

  Un nodo "campo_calculado" NO está atado a ningún campo real de
  `meta_schema_detail` — su valor sale de evaluar `propiedades["formula"]`
  (ver `MetadataApp.MetaPlantillas.Formula`, un mini-lenguaje aritmético
  seguro, nunca `Code.eval_string/1`) contra los valores efectivos del
  registro. Siempre de solo lectura: nunca se guarda, se recalcula en cada
  render.

  Un nodo "autocompletar" mira el valor ACTUAL (con cambios sin guardar
  incluidos) de CUALQUIER campo de este catálogo (no hace falta que sea
  tipo "referencia" — solo que su valor se pueda leer como entero)
  (`propiedades["campo_referencia"]`), lo usa como id para buscar UN
  registro en `propiedades["catalogo_destino"]`, y muestra de solo lectura
  los campos listados en `propiedades["campos_destino"]` — ej. elegís un
  cliente y aparecen su razón social y domicilio, sin guardar nada nuevo
  ni tocar otros controles. Se recalcula en cada render, igual que
  "campo_calculado" — si no hay selección o el registro no existe, no
  rompe la ficha.

  Los helpers de árbol (`agregar_componente/3`, `quitar_componente/2`,
  `mover_a/4`, `actualizar_propiedades/3`) NO tocan la base — el
  LiveView los llama sobre el mapa en memoria y persiste el resultado con
  `actualizar_definicion/2`. Separarlo así permite que el editor haga
  varios cambios en un socket sin ida y vuelta a la DB en cada click.
  """

  import Ecto.Query
  alias MetadataApp.Repo
  alias MetadataApp.MetaSchema.Plantilla
  alias MetadataApp.BusinessProcessBuilder.MetaSchemaContext

  def listar_plantillas(header_id) do
    from(p in Plantilla, where: p.meta_schema_header_id == ^header_id and is_nil(p.delete_guid), order_by: p.id)
    |> Repo.all()
  end

  def obtener_plantilla!(id), do: Repo.get!(Plantilla, id)

  def crear_plantilla(header_id, attrs) do
    attrs = Map.merge(%{"meta_schema_header_id" => header_id}, attrs)

    %Plantilla{}
    |> Plantilla.changeset(attrs)
    |> Ecto.Changeset.change(%{insert_guid: generar_guid()})
    |> Repo.insert()
  end

  def actualizar_definicion(%Plantilla{} = plantilla, definicion) do
    plantilla
    |> Plantilla.changeset(%{"definicion" => definicion})
    |> Ecto.Changeset.change(%{update_guid: generar_guid()})
    |> Repo.update()
  end

  # Publicar ésta implica despublicar cualquier otra del mismo catálogo —
  # el índice único parcial de la migración es la garantía real; esto es
  # la operación de aplicación que la mantiene consistente en el camino
  # feliz (todo o nada, misma transacción).
  def publicar_plantilla(%Plantilla{} = plantilla) do
    Repo.transaction(fn ->
      from(p in Plantilla,
        where: p.meta_schema_header_id == ^plantilla.meta_schema_header_id and p.estado == "publicada" and p.id != ^plantilla.id
      )
      |> Repo.update_all(set: [estado: "borrador"])

      plantilla
      |> Plantilla.changeset(%{"estado" => "publicada"})
      |> Ecto.Changeset.change(%{update_guid: generar_guid()})
      |> Repo.update()
      |> case do
        {:ok, actualizada} -> actualizada
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  def obtener_plantilla_publicada(header_id) do
    Repo.one(
      from p in Plantilla,
        where: p.meta_schema_header_id == ^header_id and p.estado == "publicada" and is_nil(p.delete_guid)
    )
  end

  # --- Árbol (puro, sin DB) ---------------------------------------------

  @propiedades_default %{
    "seccion" => %{
      "titulo" => "Nueva sección",
      "descripcion" => "",
      "visible" => true,
      "colapsable" => false,
      "icono" => "",
      "espaciado" => "normal"
    },
    "campo" => %{"campo" => nil, "tipo_filtro" => nil},
    "campo_calculado" => %{"etiqueta" => "Campo calculado", "formula" => "", "decimales" => 2},
    "autocompletar" => %{
      "titulo" => "",
      "campo_referencia" => nil,
      "catalogo_destino" => nil,
      "campos_destino" => []
    },
    "divisor" => %{},
    "tabla" => %{"catalogo" => nil, "titulo" => "Registros relacionados"},
    "etiqueta" => %{"texto" => "Texto", "estilo" => "parrafo"},
    "alerta" => %{"texto" => "Mensaje", "nivel" => "info"},
    "tarjeta" => %{"titulo" => "Tarjeta", "texto" => "", "icono" => ""},
    "fila" => %{},
    "columna" => %{},
    "panel" => %{"espaciado" => "normal"},
    "pestanas" => %{},
    "pestana" => %{"titulo" => "Pestaña"}
  }

  # Tipos que aceptan otros componentes adentro (tienen "hijos" de verdad) —
  # un solo lugar de verdad para el LiveView (qué recibe "+ agregar" cuando
  # hay un nodo de este tipo seleccionado) y para el hook de arrastre (qué
  # nodos llevan su propia lista arrastrable). Deliberadamente permisivo: no
  # valida qué tipo de hijo entra en cuál contenedor (ej. nada impide una
  # Sección adentro de una Columna) — más simple que una matriz de reglas,
  # y nada se rompe con una anidación "rara" porque el renderer de FichaLive
  # ya es recursivo genérico.
  @tipos_contenedor ["seccion", "fila", "columna", "panel", "pestanas", "pestana"]
  def tipos_contenedor, do: @tipos_contenedor

  # Filtro (botón de paleta) => lista de tipos reales de meta_schema_detail
  # que ese botón ofrece en el <select> de "qué campo mostrar" — ver
  # nota del moduledoc. "numero" agrupa integer+decimal a propósito (para
  # quien diseña la plantilla es "un número", no dos botones distintos).
  @filtros_campo %{
    "string" => ["string"],
    "numero" => ["integer", "decimal"],
    "date" => ["date"],
    "enum" => ["enum"],
    "boolean" => ["boolean"],
    "referencia" => ["referencia"]
  }

  def filtros_campo, do: @filtros_campo
  def tipos_de_filtro(filtro), do: Map.get(@filtros_campo, filtro, [])

  def nuevo_nodo(tipo) do
    %{
      "id" => generar_id_nodo(),
      "tipo" => tipo,
      "propiedades" => Map.get(@propiedades_default, tipo, %{}),
      "hijos" => []
    }
  end

  def nuevo_nodo_campo(filtro) do
    put_in(nuevo_nodo("campo"), ["propiedades", "tipo_filtro"], filtro)
  end

  @doc "Fila con 2 columnas ya adentro — layout multi-columna fijo en 2 por ahora, no configurable."
  def nuevo_nodo_fila do
    Map.put(nuevo_nodo("fila"), "hijos", [nuevo_nodo("columna"), nuevo_nodo("columna")])
  end

  @doc "Pestañas con 2 pestañas ya adentro, cada una un contenedor propio — mismo criterio que nuevo_nodo_fila/0."
  def nuevo_nodo_pestanas do
    pestana1 = put_in(nuevo_nodo("pestana"), ["propiedades", "titulo"], "Pestaña 1")
    pestana2 = put_in(nuevo_nodo("pestana"), ["propiedades", "titulo"], "Pestaña 2")
    Map.put(nuevo_nodo("pestanas"), "hijos", [pestana1, pestana2])
  end

  @doc """
  Plantilla inicial automática para un catálogo recién generado (llamada
  desde `CatalogoGenerador.generar/1`, solo la primera vez que un catálogo
  se genera — nunca en el resync de "ya existía", para no crear una
  plantilla nueva cada vez que alguien le agrega un campo). Una sección con
  todos los campos visibles del catálogo + una tabla por cada catálogo que
  lo referencia — el mismo punto de partida que armaría a mano alguien
  entrando al Constructor por primera vez. Se publica sola: mejor arrancar
  con algo mejor que la lista plana de siempre, sin depender de que
  alguien abra el Constructor.

  Best-effort a propósito: si algo falla acá NO tira abajo la generación
  del catálogo (lo que importa de verdad) — devuelve el error pero
  `CatalogoGenerador.generar/1` lo ignora.
  """
  def crear_plantilla_default(header) do
    campos =
      header.schema_context_name
      |> MetaSchemaContext.listar_detalles()
      |> Enum.map(&MetaSchemaContext.serializar_detalle/1)
      |> Enum.filter(&get_in(&1, [:schema_context_properties, "visible"]))
      |> Enum.sort_by(&get_in(&1, [:schema_context_properties, "orden"]))

    nodos_campo =
      Enum.map(campos, fn c ->
        tipo = c.schema_context_properties["tipo"]

        tipo
        |> filtro_de_tipo()
        |> nuevo_nodo_campo()
        |> put_in(["propiedades", "campo"], c.schema_context_field)
      end)

    seccion =
      nuevo_nodo("seccion")
      |> put_in(["propiedades", "titulo"], "Datos generales")
      |> Map.put("hijos", nodos_campo)

    nodos_tabla =
      header.schema_context_name
      |> MetaSchemaContext.listar_dependientes()
      |> Enum.map(fn dep ->
        etiqueta = (MetaSchemaContext.obtener_header_por_nombre(dep) || %{schema_context_label: dep}).schema_context_label

        nuevo_nodo("tabla")
        |> put_in(["propiedades", "catalogo"], dep)
        |> put_in(["propiedades", "titulo"], etiqueta)
      end)

    definicion = %{"tipo" => "raiz", "hijos" => [seccion | nodos_tabla]}

    with {:ok, plantilla} <-
           crear_plantilla(header.id, %{"nombre" => "Plantilla automática", "estado" => "borrador", "definicion" => definicion}) do
      publicar_plantilla(plantilla)
    end
  end

  defp filtro_de_tipo(tipo) do
    Enum.find_value(@filtros_campo, "string", fn {filtro, tipos} -> tipo in tipos && filtro end)
  end

  @doc "Agrega un nodo de `tipo` dentro del contenedor `contenedor_id` (o en la raíz si es nil)."
  def agregar_componente(definicion, contenedor_id, tipo) do
    insertar_nodo(definicion, contenedor_id, nuevo_nodo(tipo))
  end

  @doc "Inserta `nodo` (ya armado, ver nuevo_nodo/1) dentro de `contenedor_id` o en la raíz si es nil."
  def insertar_nodo(definicion, contenedor_id, nodo) do
    if is_nil(contenedor_id) do
      Map.update!(definicion, "hijos", &(&1 ++ [nodo]))
    else
      mapear_nodos(definicion, fn
        %{"id" => ^contenedor_id} = n -> Map.update!(n, "hijos", &(&1 ++ [nodo]))
        n -> n
      end)
    end
  end

  def quitar_componente(definicion, id) do
    Map.update!(definicion, "hijos", &quitar_de_lista(&1, id))
  end

  defp quitar_de_lista(hijos, id) do
    hijos
    |> Enum.reject(&(&1["id"] == id))
    |> Enum.map(&Map.update!(&1, "hijos", fn h -> quitar_de_lista(h, id) end))
  end

  @doc """
  Arrastrar y soltar real (ver ListaOrdenable en assets/js/app.js): saca el
  nodo `id` de donde esté y lo reinserta en `contenedor_id` (nil = raíz) en
  la posición `index` — un solo movimiento cubre tanto reordenar dentro de
  la misma lista como mover entre listas (ej. de la raíz a adentro de una
  Sección), porque Sortable.js ya avisa el destino final con un solo evento.
  """
  def mover_a(definicion, id, contenedor_id, index) do
    {nodo, sin_nodo} = extraer_nodo(definicion, id)
    if nodo, do: insertar_en_indice(sin_nodo, contenedor_id, index, nodo), else: definicion
  end

  defp extraer_nodo(definicion, id) do
    {nodo, hijos} = extraer_de_lista(definicion["hijos"], id)
    {nodo, Map.put(definicion, "hijos", hijos)}
  end

  defp extraer_de_lista(hijos, id) do
    Enum.reduce(hijos, {nil, []}, fn nodo, {encontrado, acc} ->
      cond do
        encontrado -> {encontrado, acc ++ [nodo]}
        nodo["id"] == id -> {nodo, acc}
        true ->
          {sub, nuevos_hijos} = extraer_de_lista(nodo["hijos"] || [], id)
          {sub, acc ++ [Map.put(nodo, "hijos", nuevos_hijos)]}
      end
    end)
  end

  defp insertar_en_indice(definicion, nil, index, nodo) do
    Map.update!(definicion, "hijos", &List.insert_at(&1, index, nodo))
  end

  defp insertar_en_indice(definicion, contenedor_id, index, nodo) do
    mapear_nodos(definicion, fn
      %{"id" => ^contenedor_id} = n -> Map.update!(n, "hijos", &List.insert_at(&1, index, nodo))
      n -> n
    end)
  end

  def actualizar_propiedades(definicion, id, propiedades) do
    mapear_nodos(definicion, fn
      %{"id" => ^id} = n -> Map.update!(n, "propiedades", &Map.merge(&1, propiedades))
      n -> n
    end)
  end

  def buscar_nodo(definicion, id), do: buscar_en_lista(definicion["hijos"] || [], id)

  @doc """
  Todos los nodos de `definicion` cuyo "tipo" sea `tipo`, sin importar cuán
  anidados estén (adentro de Sección/Fila/Columna/Panel/Pestañas) — ej.
  todos los `campo_calculado` de la plantilla, usado tanto por
  `PlantillaConstructorLive` (listar para referenciar uno desde otro) como
  por `FichaLive` (resolverlos todos antes de evaluar cualquier fórmula).
  """
  def nodos_de_tipo(nil, _tipo), do: []
  def nodos_de_tipo(definicion, tipo), do: (definicion["hijos"] || []) |> Enum.flat_map(&nodo_y_descendientes_de_tipo(&1, tipo))

  defp nodo_y_descendientes_de_tipo(nodo, tipo) do
    descendientes = (nodo["hijos"] || []) |> Enum.flat_map(&nodo_y_descendientes_de_tipo(&1, tipo))
    if nodo["tipo"] == tipo, do: [nodo | descendientes], else: descendientes
  end

  defp buscar_en_lista(hijos, id) do
    Enum.find_value(hijos, fn n ->
      cond do
        n["id"] == id -> n
        true -> buscar_en_lista(n["hijos"] || [], id)
      end
    end)
  end

  # Aplica `fun` a cada nodo del árbol (raíz incluida en la recursión de
  # hijos, nunca a sí misma) — usado por agregar_componente/3 (cuando
  # contenedor_id no es la raíz) y actualizar_propiedades/3.
  defp mapear_nodos(definicion, fun) do
    Map.update!(definicion, "hijos", &Enum.map(&1, fn n -> aplicar_recursivo(n, fun) end))
  end

  defp aplicar_recursivo(nodo, fun) do
    nodo
    |> fun.()
    |> Map.update!("hijos", &Enum.map(&1, fn n -> aplicar_recursivo(n, fun) end))
  end

  defp generar_id_nodo, do: Ecto.UUID.generate() |> String.replace("-", "") |> String.slice(0, 12)
  defp generar_guid, do: Ecto.UUID.generate() |> String.replace("-", "")
end
