defmodule MetadataApp.MetaSchema.Consulta do
  use Ecto.Schema
  import Ecto.Changeset

  # Un registro = la definición de un BC tipo "Consulta Ecto"
  # (schema_context_type: 3 en su Header) — sin tabla física propia, sin
  # motor de estados, sin TRN. `campos` es la lista ordenada de columnas
  # que la consulta expone (ver MetaConsultas.ejecutar/2), cada una con:
  #
  #   %{"catalogo" => nombre del catálogo dueño del campo,
  #     "campo" => nombre lógico del campo en ese catálogo,
  #     "etiqueta" => etiqueta a mostrar (si el campo no existe en
  #       meta_schema_detail de ese catálogo, se usa el nombre lógico tal
  #       cual, sin inventar una etiqueta bonita),
  #     "orden" => entero,
  #     "visible" => boolean (Get View — igual que la propiedad "visible"
  #       de un campo normal, pero acá vive en este jsonb, no en
  #       meta_schema_detail, porque un campo de consulta no es un campo
  #       real de ningún catálogo),
  #     "totalizar" => boolean (banda de totales al final de la tabla,
  #       solo aplica a columnas numéricas)}
  #
  # Rediseño de "Parámetros" (2026-08-27) -- un campo es parámetro del
  # reporte solo si el admin lo marca a propósito en Get Config, NUNCA
  # automático (corregido el mismo día: la primera versión lo hacía
  # automático para todo campo visible de tipo elegible, revertido a
  # pedido explícito -- "no todas las columnas llevan parámetro, solo
  # las que indico que llevan"). Un campo "boolean"/"enum" o no visible
  # nunca es elegible ni con el flag prendido.
  #
  #   "es_parametro" => boolean -- SOLO para tipo "date"/"string"/
  #     "referencia"/"integer"/"decimal" (los únicos elegibles); el admin
  #     lo prende explícito por columna en Get Config. false/ausente en
  #     cualquier otro caso -- MetaConsultas.campos_elegibles_fecha/1,
  #     campos_elegibles_string/1 y campos_elegibles_numerico/1 filtran
  #     por "visible" + tipo + este flag juntos.
  #
  #   "acotado" => boolean -- date/integer/decimal: elegible por el admin.
  #     string/referencia: SIEMPRE false (nunca tiene sentido "entre" para
  #     texto).
  #
  #   "tipo_filtro" => string -- date: no aplica (el widget lo decide
  #     "acotado" solo). string/referencia: "like" | "igual" | "multi".
  #     integer/decimal sin acotar: "mayor" | "menor" | "igual" |
  #     "diferente". integer/decimal acotado: siempre "entre" (fijo, no
  #     elegible).
  #
  #   "origen" => "libre" | "referenciado" -- SOLO string/referencia.
  #     "like"/"multi" fuerzan el origen ("like" -> libre, "multi" ->
  #     referenciado); "igual" es el único tipo_filtro donde el admin
  #     elige. Un campo YA tipo "referencia" (FK real) siempre es
  #     "referenciado" -- "libre" no tiene sentido ahí (no hay forma de
  #     buscar un id a mano).
  #
  #   "catalogo_referenciado" => string | nil -- SOLO cuando origen ==
  #     "referenciado". Si el campo es tipo "referencia" de verdad, se
  #     resuelve solo del destino real del FK (ver
  #     MetaSchemaContext.catalogo_sistema/1 y meta_schema_detail), este
  #     valor queda nil. Si el campo es tipo "string" genuino, el admin
  #     elige acá cualquier catálogo de MetaSchemaContext.
  #     listar_catalogos_referenciables/0 -- el filtro sigue comparando el
  #     STRING elegido contra la columna real (nunca un id/join), el
  #     catálogo solo alimenta de dónde salen las opciones.
  #
  #   "defaults" => %{} -- shape según tipo, siempre con "valor"/
  #     "valor_hasta" (rango) o "valor"/"valores" (multi), nunca un
  #     escalar suelto (uniforme para simplificar el merge de overrides
  #     de sesión, ver MetaConsultas.aplicar_filtros_*_estandar/4):
  #       date acotado:     %{"modo" =>, "valor" =>, "valor_hasta" =>}
  #                         modo: "mes_actual"|"mes_a_fecha"|"anio_actual"|"formula"
  #       date sin acotar:  %{"modo" =>, "valor" =>}
  #                         modo: "actual"|"primer_dia_mes"|"primer_dia_anio"|"formula"
  #       string libre:     %{"valor" => "texto fijo"} (puede venir vacío)
  #       string/ref igual: %{"valor" => valor elegido/tipeado}
  #       string/ref multi: %{"valores" => [lista de valores]}
  #       numérico simple:  %{"valor" => numero} (puede venir vacío)
  #       numérico entre:   %{"valor" =>, "valor_hasta" =>}
  #
  #   Nunca se filtran vía el mapa `filtros` genérico (que resuelve por
  #   nombre crudo, ambiguo si dos tablas unidas repiten nombre de campo
  #   -- ej. dos "fecha_registro") -- cada uno se resuelve directo contra
  #   SU catalogo+campo, ver MetaConsultas.aplicar_filtros_fecha_estandar/4,
  #   aplicar_filtros_string_estandar/4, aplicar_filtros_numerico_estandar/4.
  #
  # `joins` reservado para Fase 2 (todavía sin usar) — Fase 1 es una sola
  # tabla (`catalogo_base`).
  #
  # `orden_por` (Orden de resultados, R1 admin, 2026-08-27) -- lista
  # ordenada de columnas por las que ordenar el reporte, en prioridad:
  #
  #   %{"catalogo" => .., "campo" => .., "direccion" => "asc" | "desc"}
  #
  # Cualquier campo de `campos` es elegible para ordenar, visible o no --
  # a diferencia de "es_parametro" (que exige "visible" == true), ordenar
  # por una columna no la hace aparecer en la tabla. Vacío = comportamiento
  # de siempre (sin ORDER BY explícito), ver MetaConsultas.ejecutar/6.
  schema "meta_schema_consulta" do
    field :catalogo_base, :string
    field :campos, {:array, :map}, default: []
    field :joins, {:array, :map}, default: []
    field :orden_por, {:array, :map}, default: []

    field :insert_guid, :string
    field :update_guid, :string
    field :delete_guid, :string

    belongs_to :header, MetadataApp.BusinessProcessBuilder.MetaSchema.Header, foreign_key: :meta_schema_header_id

    timestamps(type: :utc_datetime)
  end

  @requeridos [:meta_schema_header_id, :catalogo_base]

  def changeset(consulta, attrs) do
    consulta
    |> cast(attrs, @requeridos ++ [:campos, :joins, :orden_por])
    |> validate_required(@requeridos)
    |> unique_constraint([:meta_schema_header_id])
    |> foreign_key_constraint(:meta_schema_header_id)
  end
end
