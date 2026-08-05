defmodule MetadataApp.MetaPlantillas do
  @moduledoc """
  Constructor de plantillas (MVP): CRUD de `MetaSchema.Plantilla` +
  manipulación pura del árbol de componentes que vive en `definicion`.

  Forma de `definicion`: `%{"tipo" => "raiz", "hijos" => [nodo, ...]}`, cada
  nodo `%{"id" => string, "tipo" => "seccion" | "fila" | "columna" | "panel"
  | "pestanas" | "pestana" | "grid" | "campo" | "campo_calculado" |
  "autocompletar" | "divisor" | "tabla" | "etiqueta" | "alerta" | "tarjeta" |
  "boton", "propiedades" => map, "hijos" => [nodo, ...]}` — solo los
  contenedores (`tipos_contenedor/0`) usan `hijos` de verdad, en el resto
  queda `[]` y no rompe nada recorrerlo igual.

  "grid" es un contenedor especial: constructor visual tipo hoja de
  cálculo (filas × columnas, colspan/rowspan). A diferencia del resto de
  `tipos_contenedor/0` (donde el ORDEN de `hijos` es el orden visual), acá
  cada hijo directo lleva su posición real en `propiedades["celda"]` (ver
  `celda_default/0`) — fila/columna/colspan/rowspan/ancho/alto/alineación/
  padding/visible/estilo/responsive. Los helpers `celda_libre?/6`,
  `colocar_en_celda/5`, `mover_celda/4`, `combinar_celdas/5`,
  `separar_celda/2`, `agregar_fila_grid/3`, `agregar_columna_grid/3`,
  `eliminar_fila_grid/3`, `eliminar_columna_grid/3` y
  `duplicar_fila_grid/3` son la única fuente de verdad de "qué celdas están
  ocupadas" — nunca se calcula a mano en el LiveView. "Varios componentes
  en una celda" no es un caso especial: el ocupante de esa celda es un
  nodo contenedor común (Panel/Columna) y los demás van adentro de ESE,
  con el drag-and-drop 1D de siempre (`mover_a/4`).

  "boton" dispara una transición YA CONFIGURADA del catálogo
  (`propiedades["accion"]`, el mismo string de acción que usan los botones
  de transición del encabezado) — no ejecuta código arbitrario.

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
    "boton" => %{"etiqueta" => "Botón", "accion" => "", "estilo" => "primario"},
    "fila" => %{},
    "columna" => %{},
    "panel" => %{"espaciado" => "normal"},
    "pestanas" => %{},
    "pestana" => %{"titulo" => "Pestaña"},
    "grid" => %{"filas" => 3, "columnas" => 4, "gap" => "normal"}
  }

  # Tipos que aceptan otros componentes adentro (tienen "hijos" de verdad) —
  # un solo lugar de verdad para el renderer de FichaLive (recursivo
  # genérico, no valida qué tipo de hijo entra en cuál contenedor — más
  # simple que una matriz de reglas). "fila"/"columna" quedan acá SOLO por
  # compatibilidad con datos viejos (ya no se generan desde el Constructor,
  # ver `tipos_grid_host/0` — todo contenedor nuevo es un grid).
  @tipos_contenedor ["seccion", "fila", "columna", "panel", "pestanas", "pestana", "grid"]
  def tipos_contenedor, do: @tipos_contenedor

  # Contenedores cuyos hijos van posicionados por celda (fila, columna) en
  # vez de por orden de lista — TODOS los contenedores "de verdad" del
  # Constructor (no existe más un modo árbol aparte, ver moduledoc "Grid
  # 2D"). "raiz" no tiene id propio — en los helpers de grid se identifica
  # con `grid_id: nil` (mismo convenio que ya usaba `insertar_nodo/3` para
  # "la raíz" antes de que existiera esto). "fila"/"columna" NO están acá:
  # son de solo lectura para datos viejos, nunca un destino de
  # colocar_en_celda/5 nuevo.
  @tipos_grid_host ["raiz", "seccion", "panel", "pestana", "grid"]
  def tipos_grid_host, do: @tipos_grid_host

  @celda_default %{
    "fila" => 0,
    "columna" => 0,
    "colspan" => 1,
    "rowspan" => 1,
    "ancho" => nil,
    "alto" => nil,
    "alineacion_h" => "izquierda",
    "alineacion_v" => "arriba",
    "padding" => "normal",
    "visible" => true,
    "estilo" => %{"fondo" => "", "borde" => false, "redondeado" => false, "sombra" => false, "color_texto" => ""},
    "responsive" => %{"ocultar_movil" => false, "colspan_movil" => nil, "rowspan_movil" => nil, "orden_movil" => nil}
  }
  def celda_default, do: @celda_default

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
  plantilla nueva cada vez que alguien le agrega un campo). La raíz misma
  arranca como un grid de 1 columna con todos los campos visibles del
  catálogo + una tabla por cada catálogo que lo referencia, cada uno su
  propia fila — el mismo punto de partida que ya arma `nuevo_nodo_grid/1`
  para un bloque Grid puntual, acá aplicado a la raíz entera (no hay más
  "modo árbol": todo PostView nuevo ES un grid desde el arranque). Se
  publica sola: mejor arrancar con algo mejor que la lista plana de
  siempre, sin depender de que alguien abra el Constructor.

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

    hijos_campo = nodos_columna_de_campos(campos)

    hijos_tabla =
      header.schema_context_name
      |> MetaSchemaContext.listar_dependientes()
      |> Enum.map(fn dep ->
        etiqueta = (MetaSchemaContext.obtener_header_por_nombre(dep) || %{schema_context_label: dep}).schema_context_label

        nuevo_nodo("tabla")
        |> put_in(["propiedades", "catalogo"], dep)
        |> put_in(["propiedades", "titulo"], etiqueta)
      end)
      |> Enum.with_index(length(hijos_campo))
      |> Enum.map(fn {nodo, i} -> set_celda(nodo, Map.merge(@celda_default, %{"fila" => i, "columna" => 0})) end)

    hijos = hijos_campo ++ hijos_tabla

    definicion = %{
      "tipo" => "raiz",
      "propiedades" => %{"filas" => max(length(hijos), 1), "columnas" => 1, "gap" => "normal"},
      "hijos" => hijos
    }

    with {:ok, plantilla} <-
           crear_plantilla(header.id, %{"nombre" => "Plantilla automática", "estado" => "borrador", "definicion" => definicion}) do
      publicar_plantilla(plantilla)
    end
  end

  defp filtro_de_tipo(tipo) do
    Enum.find_value(@filtros_campo, "string", fn {filtro, tipos} -> tipo in tipos && filtro end)
  end

  # Compartido por crear_plantilla_default/1 (arma la raíz) y
  # nuevo_nodo_grid/1 (arma un bloque Grid puntual) — un campo por fila, 1
  # sola columna, en el orden en que ya venían.
  defp nodos_columna_de_campos(campos) do
    campos
    |> Enum.with_index()
    |> Enum.map(fn {c, i} ->
      c.schema_context_properties["tipo"]
      |> filtro_de_tipo()
      |> nuevo_nodo_campo()
      |> put_in(["propiedades", "campo"], c.schema_context_field)
      |> set_celda(Map.merge(@celda_default, %{"fila" => i, "columna" => 0}))
    end)
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

  # --- Grid 2D (contenedor "grid": hijos con coordenadas explícitas) -------
  # A diferencia del resto de tipos_contenedor/0 (orden de lista = orden
  # visual, vía ListaOrdenable/mover_a), un "grid" nunca reordena su lista
  # de hijos por índice — cada hijo lleva su posición real en
  # propiedades["celda"] (@celda_default). Estos helpers son la única
  # fuente de verdad de "qué celdas están ocupadas" y "es un movimiento
  # válido" — el LiveView nunca arma esa cuenta a mano, así el Constructor
  # y (a futuro) cualquier otro caller quedan de acuerdo siempre.

  @doc """
  Grid ya poblado con 1 columna × N filas, una por cada campo real del
  catálogo — mismo criterio que `nuevo_nodo_fila/0` (2 columnas ya con
  contenido) y `nuevo_nodo_pestanas/0` (2 pestañas ya tituladas): un Grid
  3×4 completamente vacío obliga a arrastrar cada campo a mano antes de
  ver algo útil; así arranca ya usable (reordenar/combinar/agregar
  columnas es más fácil partiendo de algo real que armando desde cero).
  `campos` son los MetaSchemaDetail ya serializados que el caller ya tenga
  a mano (ver `@campos` en `PlantillaConstructorLive.montar/3` — la MISMA
  lista que ofrece el picker "Campo del catálogo"; no filtra por
  "visible", a propósito, para no desalinearse de esa paleta). Sin campos
  (catálogo recién creado, o caller que no tiene la lista) cae al Grid
  3×4 vacío de siempre.
  """
  def nuevo_nodo_grid(campos \\ [])
  def nuevo_nodo_grid([]), do: nuevo_nodo("grid")

  def nuevo_nodo_grid(campos) do
    nuevo_nodo("grid")
    |> put_in(["propiedades", "filas"], length(campos))
    |> put_in(["propiedades", "columnas"], 1)
    |> Map.put("hijos", nodos_columna_de_campos(campos))
  end

  @doc """
  `true` si el rectángulo (fila, columna, colspan, rowspan) no se solapa con
  ningún hijo YA colocado de `grid_nodo` — `excluir_id` deja afuera al
  propio nodo que se está moviendo/redimensionando (si no, siempre
  chocaría consigo mismo).
  """
  def celda_libre?(grid_nodo, fila, columna, colspan, rowspan, excluir_id \\ nil) do
    fin_fila = fila + rowspan - 1
    fin_columna = columna + colspan - 1

    Enum.all?(grid_nodo["hijos"] || [], fn hijo ->
      hijo["id"] == excluir_id or not rectangulos_solapan?(celda_de(hijo), fila, fin_fila, columna, fin_columna)
    end)
  end

  @doc """
  Coloca `nodo` (recién armado, ver `nuevo_nodo/1`/`nuevo_nodo_campo/1`)
  como hijo de `grid_id` en (fila, columna) — `{:error, :ocupada}` sin
  tocar nada si el rectángulo ya tiene algo (colspan/rowspan siempre 1 al
  colocar; se agrandan después con `combinar_celdas/5`).
  """
  def colocar_en_celda(definicion, grid_id, nodo, fila, columna) do
    grid_nodo = grid_host(definicion, grid_id)

    cond do
      is_nil(grid_nodo) ->
        {:error, :sin_grid}

      not celda_libre?(grid_nodo, fila, columna, 1, 1) ->
        {:error, :ocupada}

      true ->
        nodo_con_celda = set_celda(nodo, Map.merge(@celda_default, %{"fila" => fila, "columna" => columna}))
        {:ok, insertar_nodo(definicion, grid_id, nodo_con_celda)}
    end
  end

  @doc "Reposiciona un hijo YA existente de `grid_id` a (fila, columna) — mismo chequeo de ocupación, excluyéndose a sí mismo."
  def mover_celda(definicion, grid_id, nodo_id, fila, columna) do
    grid_nodo = grid_host(definicion, grid_id)
    nodo = grid_nodo && buscar_en_lista(grid_nodo["hijos"] || [], nodo_id)

    cond do
      is_nil(nodo) ->
        {:error, :sin_nodo}

      true ->
        celda = celda_de(nodo)

        if celda_libre?(grid_nodo, fila, columna, celda["colspan"], celda["rowspan"], nodo_id) do
          {:ok, actualizar_celda(definicion, nodo_id, %{"fila" => fila, "columna" => columna})}
        else
          {:error, :ocupada}
        end
    end
  end

  @doc """
  Agranda la celda de `nodo_id` (hijo de `grid_id`) para cubrir hasta
  (fila_fin, columna_fin) — `{:error, :ocupada}` si alguna OTRA celda del
  rectángulo resultante ya tiene algo puesto.
  """
  def combinar_celdas(definicion, grid_id, nodo_id, fila_fin, columna_fin) do
    grid_nodo = grid_host(definicion, grid_id)
    nodo = grid_nodo && buscar_en_lista(grid_nodo["hijos"] || [], nodo_id)

    case nodo do
      nil ->
        {:error, :sin_nodo}

      _ ->
        celda = celda_de(nodo)
        fila = min(celda["fila"], fila_fin)
        columna = min(celda["columna"], columna_fin)
        rowspan = abs(fila_fin - celda["fila"]) + 1
        colspan = abs(columna_fin - celda["columna"]) + 1

        if celda_libre?(grid_nodo, fila, columna, colspan, rowspan, nodo_id) do
          {:ok, actualizar_celda(definicion, nodo_id, %{"fila" => fila, "columna" => columna, "colspan" => colspan, "rowspan" => rowspan})}
        else
          {:error, :ocupada}
        end
    end
  end

  @doc "Vuelve la celda de `nodo_id` a 1×1 (colspan/rowspan), sin mover su esquina superior izquierda."
  def separar_celda(definicion, nodo_id), do: actualizar_celda(definicion, nodo_id, %{"colspan" => 1, "rowspan" => 1})

  @doc "Mergea `cambios` dentro de propiedades[\"celda\"] de `id` (parte de @celda_default si el nodo todavía no tenía celda) — mismo patrón que actualizar_propiedades/3, un nivel más adentro."
  def actualizar_celda(definicion, id, cambios) do
    mapear_nodos(definicion, fn
      %{"id" => ^id} = n -> set_celda(n, Map.merge(celda_de(n), cambios))
      n -> n
    end)
  end

  @doc "Inserta una fila vacía en `indice` de `grid_id` — empuja +1 la fila de lo que ya estaba ahí o más abajo, y sube propiedades[\"filas\"]."
  def agregar_fila_grid(definicion, grid_id, indice) do
    transformar_grid(definicion, grid_id, fn grid_nodo ->
      grid_nodo
      |> Map.update!("hijos", fn hijos ->
        Enum.map(hijos, fn hijo ->
          celda = celda_de(hijo)
          if celda["fila"] >= indice, do: set_celda(hijo, %{celda | "fila" => celda["fila"] + 1}), else: hijo
        end)
      end)
      |> update_in(["propiedades", "filas"], &((&1 || 1) + 1))
    end)
  end

  @doc "Igual que agregar_fila_grid/3 pero en columnas."
  def agregar_columna_grid(definicion, grid_id, indice) do
    transformar_grid(definicion, grid_id, fn grid_nodo ->
      grid_nodo
      |> Map.update!("hijos", fn hijos ->
        Enum.map(hijos, fn hijo ->
          celda = celda_de(hijo)
          if celda["columna"] >= indice, do: set_celda(hijo, %{celda | "columna" => celda["columna"] + 1}), else: hijo
        end)
      end)
      |> update_in(["propiedades", "columnas"], &((&1 || 1) + 1))
    end)
  end

  @doc """
  Quita la fila `indice` de `grid_id`: los nodos que EMPIEZAN ahí se
  eliminan del todo; los que la atraviesan (rowspan que arrancó antes y
  llega hasta acá) se acortan un lugar; el resto de las filas se corre -1.
  Nunca deja el grid en 0 filas (mínimo 1).
  """
  def eliminar_fila_grid(definicion, grid_id, indice) do
    transformar_grid(definicion, grid_id, fn grid_nodo ->
      grid_nodo
      |> Map.update!("hijos", fn hijos ->
        hijos
        |> Enum.reject(fn hijo -> celda_de(hijo)["fila"] == indice end)
        |> Enum.map(fn hijo ->
          celda = celda_de(hijo)

          cond do
            celda["fila"] > indice -> set_celda(hijo, %{celda | "fila" => celda["fila"] - 1})
            celda["fila"] < indice and celda["fila"] + celda["rowspan"] - 1 >= indice -> set_celda(hijo, %{celda | "rowspan" => max(celda["rowspan"] - 1, 1)})
            true -> hijo
          end
        end)
      end)
      |> update_in(["propiedades", "filas"], &max((&1 || 1) - 1, 1))
    end)
  end

  @doc "Igual que eliminar_fila_grid/3 pero en columnas."
  def eliminar_columna_grid(definicion, grid_id, indice) do
    transformar_grid(definicion, grid_id, fn grid_nodo ->
      grid_nodo
      |> Map.update!("hijos", fn hijos ->
        hijos
        |> Enum.reject(fn hijo -> celda_de(hijo)["columna"] == indice end)
        |> Enum.map(fn hijo ->
          celda = celda_de(hijo)

          cond do
            celda["columna"] > indice -> set_celda(hijo, %{celda | "columna" => celda["columna"] - 1})
            celda["columna"] < indice and celda["columna"] + celda["colspan"] - 1 >= indice -> set_celda(hijo, %{celda | "colspan" => max(celda["colspan"] - 1, 1)})
            true -> hijo
          end
        end)
      end)
      |> update_in(["propiedades", "columnas"], &max((&1 || 1) - 1, 1))
    end)
  end

  @doc "Duplica la fila `indice` de `grid_id`: inserta una fila nueva justo abajo con copias (ids nuevos) de todo lo que había en la original."
  def duplicar_fila_grid(definicion, grid_id, indice) do
    grid_nodo = grid_host(definicion, grid_id)
    originales = Enum.filter((grid_nodo && grid_nodo["hijos"]) || [], &(celda_de(&1)["fila"] == indice))

    definicion
    |> agregar_fila_grid(grid_id, indice + 1)
    |> entonces_duplicar(grid_id, originales, indice + 1)
  end

  defp entonces_duplicar(definicion, grid_id, originales, fila_destino) do
    Enum.reduce(originales, definicion, fn original, acc ->
      copia = original |> clonar_nodo() |> set_celda(Map.put(celda_de(original), "fila", fila_destino))
      insertar_nodo(acc, grid_id, copia)
    end)
  end

  defp clonar_nodo(nodo) do
    nodo
    |> Map.put("id", generar_id_nodo())
    |> Map.update!("hijos", &Enum.map(&1, fn h -> clonar_nodo(h) end))
  end

  @doc """
  Nodo "anfitrión" de grid identificado por `grid_id` (o `nil` = la raíz
  misma, mismo convenio que `insertar_nodo/3`), con sus hijos YA resueltos
  por celda (ver `celdas_resueltas/1`) — pública porque no es solo un
  detalle interno: `PlantillaConstructorLive.grid_editor/1` y
  `FichaLive.celda_grid/1` la usan tal cual para saber qué renderizar,
  así nunca hay una segunda copia de "qué significa nil" del lado de cada
  caller. `nil` si `grid_id` no existe (nodo borrado mientras alguien más
  lo tenía seleccionado, por ejemplo).
  """
  def grid_host(definicion, nil), do: resolver_hijos(definicion)
  def grid_host(definicion, id), do: definicion |> buscar_nodo(id) |> resolver_hijos()

  defp resolver_hijos(nil), do: nil

  # Dos cosas a la vez para cualquier nodo viejo que todavía no pasó por
  # acá (Sección/Panel/la raíz misma de un catálogo que no tocó un grid en
  # esta sesión):
  #   1. Garantiza que `propiedades` sea un mapa real (nunca ausente) —
  #      SIN esto, los `update_in(["propiedades", "filas"], ...)` de
  #      agregar_fila_grid/3 y compañía (más abajo) explotan: a diferencia
  #      de leer (`nodo["propiedades"]["filas"]`, tolerante a nil),
  #      `update_in`/`Access.get_and_update` NO tolera un nil intermedio —
  #      "Agregar fila/columna" se rompía en silencio (el proceso de
  #      LiveView crasheaba y reconectaba) en cualquier contenedor sin
  #      "propiedades" todavía, bug real, reportado.
  #   2. Sube "filas"/"columnas" para que como mínimo cubran lo que
  #      celdas_resueltas/1 ya numeró — un contenedor recién migrado con 2
  #      hijos pero sin "columnas"/"filas" propias quedaría atascado en el
  #      default de 1, aunque en realidad ya ocupa 2 filas.
  defp resolver_hijos(nodo) do
    hijos = celdas_resueltas(nodo["hijos"] || [])
    {filas_min, columnas_min} = extension_minima(hijos)
    propiedades = nodo["propiedades"] || %{}

    propiedades =
      propiedades
      |> Map.put("filas", max(propiedades["filas"] || 1, filas_min))
      |> Map.put("columnas", max(propiedades["columnas"] || 1, columnas_min))

    nodo |> Map.put("hijos", hijos) |> Map.put("propiedades", propiedades)
  end

  defp extension_minima(hijos) do
    Enum.reduce(hijos, {1, 1}, fn hijo, {f, c} ->
      celda = celda_de(hijo)
      {max(f, celda["fila"] + celda["rowspan"]), max(c, celda["columna"] + celda["colspan"])}
    end)
  end

  @doc """
  Resuelve la celda de una lista de hijos EN CONJUNTO (no nodo por nodo) —
  distingue tres casos:

  - Ninguno tiene `propiedades["celda"]` todavía (Sección/Panel armados con
    el árbol de antes, en cualquier catálogo que no haya tocado un grid en
    esta sesión): se numeran 1 columna × N filas en el mismo orden que ya
    tenía la lista — mismo resultado visual que el flex-col/lista de
    siempre, ahora expresado como coordenadas. Nunca hace falta una
    migración de datos aparte, se resuelve solo al leer.
  - Todos ya tienen celda (caso normal, un grid armado desde acá): se
    devuelven tal cual.
  - Mezcla (alta nueva sobre un contenedor recién migrado a medias): los
    que ya tienen celda se respetan; los que no, van al primer hueco libre
    de la columna 0 hacia abajo.

  Pública porque el render final (`FichaLive.celda_grid/1`) y el editor
  (`PlantillaConstructorLive.grid_editor/1`) necesitan la MISMA resolución
  en grupo para mostrar exactamente lo que después va a aceptar/rechazar
  `celda_libre?/6` — nunca se resuelve nodo por nodo de forma aislada
  (ahí es donde un default de "fila:0,columna:0" para cada uno los haría
  apilarse todos en la misma celda).
  """
  def celdas_resueltas(hijos) do
    if Enum.all?(hijos, &is_nil(&1["propiedades"]["celda"])) do
      hijos
      |> Enum.with_index()
      |> Enum.map(fn {h, i} -> set_celda(h, Map.merge(@celda_default, %{"fila" => i, "columna" => 0})) end)
    else
      {resueltos, _ocupadas} =
        Enum.map_reduce(hijos, MapSet.new(), fn hijo, ocupadas ->
          if hijo["propiedades"]["celda"] do
            {hijo, marcar_ocupadas(ocupadas, celda_de(hijo))}
          else
            {fila, columna} = primer_hueco(ocupadas)
            celda = Map.merge(@celda_default, %{"fila" => fila, "columna" => columna})
            {set_celda(hijo, celda), marcar_ocupadas(ocupadas, celda)}
          end
        end)

      resueltos
    end
  end

  defp marcar_ocupadas(ocupadas, celda) do
    for f <- celda["fila"]..(celda["fila"] + celda["rowspan"] - 1),
        c <- celda["columna"]..(celda["columna"] + celda["colspan"] - 1),
        reduce: ocupadas do
      acc -> MapSet.put(acc, {f, c})
    end
  end

  defp primer_hueco(ocupadas) do
    Enum.find_value(Stream.iterate(0, &(&1 + 1)), fn f ->
      if not MapSet.member?(ocupadas, {f, 0}), do: {f, 0}
    end)
  end

  @doc """
  Ancestros de `id` (o `nil` = raíz) desde la raíz hasta ese nodo, uno por
  cada Sección/Panel/Pestaña/Grid que hay que atravesar — arma el
  breadcrumb del editor (`PlantillaConstructorLive.grid_editor/1`), que ya
  no tiene un botón fijo "Volver al árbol": cada segmento navega con
  `entrar_contenedor` directo a ESE id. Se deriva de `definicion` en cada
  llamada (nunca se guarda como estado propio), así nunca puede
  desincronizarse de un cambio hecho por otro lado.
  """
  def ruta_hasta(_definicion, nil), do: [%{id: nil, etiqueta: "Raíz"}]

  def ruta_hasta(definicion, id) do
    # `nil` si `id` ya no existe (alguien lo borró desde otra sesión
    # mientras esta lo tenía abierto) — el breadcrumb cae a solo "Raíz" en
    # vez de explotar, mismo criterio permisivo que el resto del módulo.
    case camino_hasta(definicion["hijos"] || [], id, []) do
      nil -> [%{id: nil, etiqueta: "Raíz"}]
      camino -> [%{id: nil, etiqueta: "Raíz"} | Enum.map(camino, &%{id: &1["id"], etiqueta: etiqueta_ruta(&1)})]
    end
  end

  defp camino_hasta(hijos, id, acc) do
    Enum.find_value(hijos, fn n ->
      cond do
        n["id"] == id -> Enum.reverse([n | acc])
        true -> camino_hasta(n["hijos"] || [], id, [n | acc])
      end
    end)
  end

  defp etiqueta_ruta(%{"tipo" => "seccion", "propiedades" => %{"titulo" => t}}), do: t || "Sección"
  defp etiqueta_ruta(%{"tipo" => "panel"}), do: "Panel"
  defp etiqueta_ruta(%{"tipo" => "pestana", "propiedades" => %{"titulo" => t}}), do: t || "Pestaña"
  defp etiqueta_ruta(%{"tipo" => "grid"}), do: "Grid"
  defp etiqueta_ruta(n), do: n["tipo"]

  defp celda_de(nodo), do: Map.merge(@celda_default, nodo["propiedades"]["celda"] || %{})
  defp set_celda(nodo, celda), do: put_in(nodo, ["propiedades", "celda"], celda)

  defp rectangulos_solapan?(celda, fila, fin_fila, columna, fin_columna) do
    hf = celda["fila"]
    hc = celda["columna"]
    hf_fin = hf + celda["rowspan"] - 1
    hc_fin = hc + celda["colspan"] - 1

    hf <= fin_fila and hf_fin >= fila and hc <= fin_columna and hc_fin >= columna
  end

  defp transformar_grid(definicion, nil, fun), do: definicion |> resolver_hijos() |> fun.()

  defp transformar_grid(definicion, grid_id, fun) do
    mapear_nodos(definicion, fn
      %{"id" => ^grid_id} = n -> n |> resolver_hijos() |> fun.()
      n -> n
    end)
  end

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
