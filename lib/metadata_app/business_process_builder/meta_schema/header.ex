defmodule MetadataApp.BusinessProcessBuilder.MetaSchema.Header do
  use Ecto.Schema
  import Ecto.Changeset

  schema "meta_schema_header" do
    field :schema_context_name, :string
    field :schema_context_label, :string
    field :schema_context_type, :integer, default: 1
    field :schema_context_nav, :string
    field :schema_context_icono, :string
    field :schema_visible, :boolean
    field :schema_set_permissions, :map
    field :schema_profiles, :map

    # Get View → Filtros (bc_motor_live.ex): si está en true, la tabla del
    # catálogo (CatalogoLive) trae TODOS los registros y columnas apenas
    # se abre, sin esperar que el usuario final aplique un filtro/búsqueda
    # primero — ver datos_solicitados?/1 en catalogo_live.ex. El usuario
    # final igual puede seguir filtrando después con los filtros normales,
    # esto solo cambia el estado inicial.
    field :cargar_todos_por_default, :boolean, default: false

    # "Filtros por default" (bc_motor_live.ex, independiente de
    # cargar_todos_por_default) — acota lo que ve el usuario final por
    # fecha de ALTA, filtrando directo sobre la columna real
    # "fecha_registro" (ver MetaCatalogoGenerico, en TODA tabla de
    # catálogo desde 2026-08-06). Modos: "primer_dia_anio" (desde el 1/1 del AÑO de
    # filtro_default_fecha_valor, elegido por calendario), "ultimo_dia_anio"
    # (hasta el 31/12 del año de filtro_default_fecha_valor), "actual" (el
    # día exacto de filtro_default_fecha_valor, elegido por calendario —
    # ya no siempre "hoy"), "rango" (usa filtro_default_fecha_valor como
    # desde y filtro_default_fecha_valor_hasta como hasta, ambos
    # obligatorios). nil = sin acotar por fecha.
    field :filtro_default_fecha_modo, :string
    field :filtro_default_fecha_valor, :date
    field :filtro_default_fecha_valor_hasta, :date

    # PrettyCore TRN (Transaction Reference Number) — separado a propósito
    # de schema_context_type (que ya usa 2 para "carpeta", una dimensión
    # distinta a "es transaccional"). codigo_trn (ej. "VENT") solo es
    # obligatorio cuando schema_es_transaccional: true — ver changeset/2.
    field :schema_es_transaccional, :boolean, default: false
    field :codigo_trn, :string

    # Get View → columnas ESTRUCTURALES (bc_motor_live.ex, 2026-08-06) — a
    # diferencia de cargar_todos_por_default/filtro_default_fecha_* (qué
    # filas trae), esto es qué COLUMNAS de sistema muestra CatalogoLive:
    # ID siempre existía sin ningún gate, Estado/TRN ya se ocultaban solos
    # cuando el catálogo no calificaba (sin motor de estados / no
    # transaccional) pero sin forma de que un admin los ocultara aunque
    # calificaran. default: true en los 3 preserva el comportamiento de
    # siempre para catálogos ya publicados.
    field :mostrar_id_en_tabla, :boolean, default: true
    field :mostrar_estado_en_tabla, :boolean, default: true
    field :mostrar_trn_en_tabla, :boolean, default: true

    # Alcance de Datos (Fase 3, 2026-08-11) -- default false: filas de este
    # catálogo se ven/editan sin ningún filtro adicional hasta que un admin
    # lo prenda a mano (BcMotorLive, Fase 6). El "QUÉ TIPO" de alcance no
    # vive acá -- es por (rol, catálogo), ver meta_schema_rol_alcance /
    # MetadataApp.Permissions.alcance_tipo_efectivo/2.
    field :alcance_habilitado, :boolean, default: false

    # Get View → columnas de Alcance de Datos (2026-08-12) -- mismo
    # criterio que mostrar_id_en_tabla/mostrar_estado_en_tabla arriba,
    # pero estas 4 SOLO tienen sentido (y CatalogoLive las hace AND con
    # alcance_habilitado antes de mostrarlas) cuando el catálogo activó
    # Alcance de Datos: sin eso, branch_id/sales_unit_id/inventory_id ni
    # existen como columna física en la tabla generada. "Empresa" no es
    # una columna física propia -- se resuelve por fila vía
    # branch_id → Branch.empresa_id, ver CatalogoLive.mapa_nombres_alcance/2.
    field :mostrar_empresa_en_tabla, :boolean, default: true
    field :mostrar_branch_en_tabla, :boolean, default: true
    field :mostrar_inventory_location_en_tabla, :boolean, default: true
    field :mostrar_sales_unit_en_tabla, :boolean, default: true

    # "Creado por" (Get View → Campos de Control) — no es columna física
    # propia, se resuelve contra meta_schema_auditoria (bc + entidad_id,
    # operacion "alta"; el maestro cuando el catálogo es detalle), mismo
    # criterio que "Empresa" arriba (tampoco es columna propia).
    field :mostrar_creado_por_en_tabla, :boolean, default: false

    # Get View unificado (Campos de Control + Campos de negocio en una
    # sola grilla arrastrable) — orden combinado de claves: nombres de
    # campo real (schema_context_field) y claves fijas de control ("id",
    # "estado", "trn", "empresa", "branch", "inventory_location",
    # "sales_unit", "creado_por"). [] = nunca configurado, CatalogoLive
    # cae al orden de siempre. No reemplaza el "orden" propio de cada
    # campo (schema_context_properties, usado por la pestaña Campos/Ficha/
    # contrato de API) — es aparte, específico de esta grilla.
    field :orden_columnas_tabla, {:array, :string}, default: []

    # Catálogo Maestro-Detalle (ver docs/catalogo-maestro-detalle-requerimientos.md,
    # R1/R16) — no nulo implica "este catálogo es detalle de otro". No se
    # reusó schema_context_type (ya usa 2 para "carpeta", otra dimensión)
    # por el mismo criterio que separó schema_es_transaccional de ese campo.
    field :schema_encabezado_id, :id

    # Orden manual (drag-and-drop) entre hermanos del mismo nivel del árbol
    # — hoy solo se edita para carpetas raíz (ver "Editar vista" en
    # BcListLive), pero MetaSchemaContext.mapa_a_lista_ordenada/1 lo respeta
    # en cualquier nivel. nil = sin ordenar a mano, cae al alfabético de
    # siempre.
    field :orden, :integer

    field :insert_guid, :string
    field :update_guid, :string
    field :delete_guid, :string

    has_many :detalles, MetadataApp.BusinessProcessBuilder.MetaSchema.Detail, foreign_key: :meta_schema_header_id
    has_many :estados, MetadataApp.MetaSchema.Estado, foreign_key: :meta_schema_header_id
    has_many :transiciones, MetadataApp.MetaSchema.Transicion, foreign_key: :meta_schema_header_id
  end

  @requeridos [
    :schema_context_name,
    :schema_context_label,
    :schema_context_type,
    :schema_context_nav,
    :schema_visible
  ]

  def changeset(header, attrs) do
    header
    |> cast(
      attrs,
      @requeridos ++
        [
          :schema_context_icono,
          :schema_set_permissions,
          :schema_profiles,
          :schema_es_transaccional,
          :codigo_trn,
          :schema_encabezado_id,
          :orden,
          :cargar_todos_por_default,
          :filtro_default_fecha_modo,
          :filtro_default_fecha_valor,
          :filtro_default_fecha_valor_hasta,
          :mostrar_id_en_tabla,
          :mostrar_estado_en_tabla,
          :mostrar_trn_en_tabla,
          :alcance_habilitado,
          :mostrar_empresa_en_tabla,
          :mostrar_branch_en_tabla,
          :mostrar_inventory_location_en_tabla,
          :mostrar_sales_unit_en_tabla,
          :mostrar_creado_por_en_tabla,
          :orden_columnas_tabla
        ]
    )
    |> validate_required(@requeridos)
    |> update_change(:codigo_trn, &nil_si_vacio_o_mayusculas/1)
    |> validar_codigo_trn()
    |> validar_encabezado()
    |> unique_constraint(:schema_context_name)
    |> unique_constraint(:codigo_trn, name: :meta_schema_header_codigo_trn_unico_index)
  end

  defp nil_si_vacio_o_mayusculas(nil), do: nil
  defp nil_si_vacio_o_mayusculas(""), do: nil
  defp nil_si_vacio_o_mayusculas(valor), do: String.upcase(valor)

  # codigo_trn (el "VENT" de VENT-260721-104537-4832) solo es obligatorio
  # cuando el catálogo se marca transaccional — un catálogo normal no
  # necesita ninguno. 4 letras/dígitos exactos: es el prefijo fijo del TRN
  # público, tiene que caber en el formato sin ambigüedad.
  defp validar_codigo_trn(changeset) do
    if get_field(changeset, :schema_es_transaccional) do
      changeset
      |> validate_required(:codigo_trn, message: "es obligatorio para un catálogo transaccional")
      |> validate_format(:codigo_trn, ~r/^[A-Z0-9]{4}$/, message: "debe ser exactamente 4 letras/dígitos (ej. VENT)")
    else
      changeset
    end
  end

  # Multinivel (Fase 0 del módulo de Importación, 2026-08-27): el maestro
  # tiene que ser un catálogo normal (schema_context_type == 1, no una
  # carpeta) — YA NO tiene que ser "raíz" (antes se rechazaba que un
  # catálogo detalle fuera a su vez maestro de otro, "sin multinivel").
  # Ahora una cadena Pedido → Partidas → Lotes → Series es válida; lo único
  # que sigue prohibido es un CICLO (ver forma_ciclo?/3 — A detalle de B que
  # ya es detalle de A, directo o a través de más eslabones). Consulta eager
  # acá mismo (no vía MetaSchemaContext, para no crear una dependencia de
  # Header hacia su propio módulo de contexto) — mismo criterio que ya usa
  # CatalogoGenerador.validar_referencias/1 para "referencia".
  defp validar_encabezado(changeset) do
    case get_field(changeset, :schema_encabezado_id) do
      nil ->
        changeset

      id ->
        case MetadataApp.Repo.get(__MODULE__, id) do
          nil ->
            add_error(changeset, :schema_encabezado_id, "el catálogo maestro no existe")

          %__MODULE__{delete_guid: dg} when not is_nil(dg) ->
            add_error(changeset, :schema_encabezado_id, "el catálogo maestro no existe")

          %__MODULE__{schema_context_type: tipo} when tipo != 1 ->
            add_error(changeset, :schema_encabezado_id, "el catálogo maestro debe ser un catálogo, no una carpeta")

          maestro ->
            if forma_ciclo?(maestro, changeset.data.id) do
              add_error(
                changeset,
                :schema_encabezado_id,
                "formaría un ciclo de maestro-detalle: este catálogo ya es antepasado de \"#{maestro.schema_context_name}\""
              )
            else
              changeset
            end
        end
    end
  end

  # Camina la cadena schema_encabezado_id hacia arriba desde `maestro` — si
  # en algún punto llega a `propio_id` (el catálogo que se está editando),
  # sería un ciclo. `propio_id` es nil en un alta (catálogo todavía sin id,
  # no puede formar un ciclo consigo mismo todavía) — solo aplica al editar
  # el schema_encabezado_id de uno YA existente. `visitados` es puramente
  # defensivo (esta misma validación impide que se guarde un ciclo desde
  # acá en adelante, pero protege contra recursión infinita si alguna vez
  # hubiera uno preexistente en la base).
  defp forma_ciclo?(_maestro, nil), do: false
  defp forma_ciclo?(maestro, propio_id), do: forma_ciclo_desde?(maestro, propio_id, MapSet.new())

  defp forma_ciclo_desde?(%__MODULE__{id: id}, propio_id, _visitados) when id == propio_id, do: true
  defp forma_ciclo_desde?(%__MODULE__{schema_encabezado_id: nil}, _propio_id, _visitados), do: false

  defp forma_ciclo_desde?(%__MODULE__{id: id, schema_encabezado_id: siguiente_id}, propio_id, visitados) do
    if MapSet.member?(visitados, id) do
      false
    else
      case MetadataApp.Repo.get(__MODULE__, siguiente_id) do
        nil -> false
        siguiente -> forma_ciclo_desde?(siguiente, propio_id, MapSet.put(visitados, id))
      end
    end
  end
end
