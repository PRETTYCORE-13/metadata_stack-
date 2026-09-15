defmodule MetadataApp.MetaSchema.ConsultaEndpoint do
  use Ecto.Schema
  import Ecto.Changeset

  alias MetadataApp.ParametrosCatalogo
  alias MetadataApp.BusinessProcessBuilder.MetaSchemaContext

  # Un registro = la configuración del endpoint API público de UNA
  # Consulta (SPEC-SYS-1009202602) -- como máximo uno por Consulta
  # (unique_index sobre meta_schema_consulta_id).
  #
  #   "parametros" => [%{"campo" => "<catalogo>__<campo>", "obligatorio" => bool}, ...]
  #     "campo" es la MISMA clave namespaced que devuelve
  #     ParametrosCatalogo.clave_campo/1 (como string, no átomo -- jsonb
  #     no tiene átomos), para que nunca choque con un campo de otra
  #     tabla unida con el mismo nombre lógico.
  #
  #   "estado" => "borrador" | "publicado"
  #
  # La API key YA NO vive acá (cambio 2026-09-11, R19.1) -- un endpoint
  # puede tener VARIAS credenciales, cada una con su propio hash/sufijo
  # y su propio subconjunto de campos permitidos, ver
  # MetaSchema.ConsultaEndpointCredencial.
  schema "meta_schema_consulta_endpoint" do
    field :nombre, :string
    field :metodo, :string
    field :ruta, :string
    field :descripcion, :string
    field :parametros, {:array, :map}, default: []
    field :estado, :string, default: "borrador"
    field :empresa_id, :id

    # R54-R58 (agregado 2026-09-14) -- un endpoint POST puede, además de
    # consultar, insertar un registro nuevo en su catálogo base. Ver
    # ConsultaEndpoints.crear_registro/3.
    field :permite_alta, :boolean, default: false
    field :campos_alta, {:array, :string}, default: []

    # R59-R61 (agregado 2026-09-14) -- si catalogo_base es un MAESTRO,
    # el alta puede crear también los renglones iniciales de sus
    # catálogos detalle: [%{"catalogo" => "<catalogo_detalle>", "campos" => [...]}, ...].
    field :renglones_alta, {:array, :map}, default: []

    field :insert_guid, :string
    field :update_guid, :string
    field :delete_guid, :string

    belongs_to :consulta, MetadataApp.MetaSchema.Consulta, foreign_key: :meta_schema_consulta_id
    has_many :credenciales, MetadataApp.MetaSchema.ConsultaEndpointCredencial, foreign_key: :meta_schema_consulta_endpoint_id

    timestamps(type: :utc_datetime)
  end

  @metodos ["get", "post"]
  @estados ["borrador", "publicado"]
  @requeridos [:meta_schema_consulta_id, :nombre, :metodo, :ruta, :empresa_id]

  def changeset(endpoint, attrs, consulta \\ nil) do
    endpoint
    |> cast(attrs, @requeridos ++ [:descripcion, :parametros, :estado, :permite_alta, :campos_alta, :renglones_alta])
    |> validate_required(@requeridos)
    |> validate_inclusion(:metodo, @metodos)
    |> validate_inclusion(:estado, @estados)
    |> validate_format(:ruta, ~r/^[a-z0-9-]+$/,
      message: "solo minúsculas, números y guiones, sin barras"
    )
    |> validar_parametros_vigentes(consulta)
    |> validar_campos_alta_vigentes(consulta)
    |> validar_renglones_alta_vigentes(consulta)
    |> unique_constraint(:meta_schema_consulta_id)
    |> unique_constraint([:metodo, :ruta], name: :meta_schema_consulta_endpoint_metodo_ruta_index)
    |> foreign_key_constraint(:meta_schema_consulta_id)
    |> foreign_key_constraint(:empresa_id)
  end

  # R8.1 -- cada "campo" de `parametros` debe seguir siendo un Parámetro
  # vigente de la Consulta (visible, tipo elegible, "es_parametro" =>
  # true) en el momento de guardar. Sin `consulta` (ej. changeset
  # aislado en un test unitario que no lo necesita) esta validación se
  # omite -- quien llama desde el contexto siempre la pasa.
  defp validar_parametros_vigentes(changeset, nil), do: changeset

  defp validar_parametros_vigentes(changeset, consulta) do
    claves_vigentes =
      (ParametrosCatalogo.campos_elegibles_fecha(consulta.campos) ++
         ParametrosCatalogo.campos_elegibles_string(consulta.campos) ++
         ParametrosCatalogo.campos_elegibles_numerico(consulta.campos))
      |> Enum.map(&(ParametrosCatalogo.clave_campo(&1) |> to_string()))
      |> MapSet.new()

    parametros = get_field(changeset, :parametros) || []

    invalidos =
      parametros
      |> Enum.map(& &1["campo"])
      |> Enum.reject(&MapSet.member?(claves_vigentes, &1))

    case invalidos do
      [] ->
        changeset

      campos ->
        add_error(
          changeset,
          :parametros,
          "ya no son parámetros vigentes de la Consulta: #{Enum.join(campos, ", ")}"
        )
    end
  end

  # R54 -- cada "campo" de `campos_alta` debe seguir siendo un campo
  # real del catálogo base (mismo criterio que validar_parametros_vigentes/2
  # de arriba, pero contra los campos REALES del catálogo -- vía
  # meta_schema_detail -- no contra los de la Consulta, que son un
  # subconjunto/namespace distinto).
  defp validar_campos_alta_vigentes(changeset, nil), do: changeset

  defp validar_campos_alta_vigentes(changeset, consulta) do
    claves_reales =
      consulta.catalogo_base
      |> MetaSchemaContext.listar_detalles()
      |> MapSet.new(& &1.schema_context_field)

    campos_alta = get_field(changeset, :campos_alta) || []
    invalidos = Enum.reject(campos_alta, &MapSet.member?(claves_reales, &1))

    case invalidos do
      [] ->
        changeset

      campos ->
        add_error(
          changeset,
          :campos_alta,
          "ya no son campos vigentes del catálogo base: #{Enum.join(campos, ", ")}"
        )
    end
  end

  # R59-R61 -- cada entrada de `renglones_alta` tiene que seguir siendo
  # (a) un catálogo detalle REAL del catalogo_base (schema_encabezado_id
  # apunta al header de catalogo_base) y (b) sus "campos" siguen siendo
  # campos reales de ESE catálogo detalle -- mismo espíritu que
  # validar_campos_alta_vigentes/2, un nivel más abajo.
  defp validar_renglones_alta_vigentes(changeset, nil), do: changeset

  defp validar_renglones_alta_vigentes(changeset, consulta) do
    with %{id: header_maestro_id} <- MetaSchemaContext.obtener_header_por_nombre(consulta.catalogo_base) do
      catalogos_detalle_validos =
        header_maestro_id
        |> MetaSchemaContext.listar_catalogos_detalle()
        |> MapSet.new(& &1.schema_context_name)

      renglones_alta = get_field(changeset, :renglones_alta) || []

      invalidos =
        Enum.reject(renglones_alta, fn entrada ->
          catalogo = entrada["catalogo"]

          MapSet.member?(catalogos_detalle_validos, catalogo) and
            campos_entrada_vigentes?(catalogo, entrada["campos"] || [])
        end)

      case invalidos do
        [] ->
          changeset

        entradas ->
          catalogos = Enum.map(entradas, & &1["catalogo"])
          add_error(changeset, :renglones_alta, "configuración de renglones inválida para: #{Enum.join(catalogos, ", ")}")
      end
    else
      _ -> changeset
    end
  end

  defp campos_entrada_vigentes?(catalogo, campos) do
    claves_reales = catalogo |> MetaSchemaContext.listar_detalles() |> MapSet.new(& &1.schema_context_field)
    Enum.all?(campos, &MapSet.member?(claves_reales, &1))
  end
end
