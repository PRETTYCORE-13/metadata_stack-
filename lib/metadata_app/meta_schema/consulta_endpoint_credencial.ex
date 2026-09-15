defmodule MetadataApp.MetaSchema.ConsultaEndpointCredencial do
  use Ecto.Schema
  import Ecto.Changeset

  # Una credencial de acceso a un endpoint publicado (SPEC-SYS-1009202602,
  # R19.1, R42-R46, design.md §1.2) -- MUCHAS por endpoint (cada sistema
  # externo que lo consume recibe la suya, nunca comparten una).
  #
  #   "api_key_hash"/"api_key_sufijo" -- mismo criterio que ya usaba el
  #   endpoint en la v1 de esta spec (hash de un solo sentido, R25):
  #   la key completa NUNCA se vuelve a leer después de crear/regenerar.
  #
  #   "campos_permitidos" -- lista de claves namespaced (mismo formato
  #   que ParametrosCatalogo.clave_campo/1, como string) -- subconjunto
  #   de los campos VISIBLES del endpoint. La respuesta de una llamada
  #   real con esta credencial nunca trae más que esto (R43-R44).
  #
  #   "estado" => "activa" | "revocada" -- revocar NO borra la fila
  #   (delete_guid queda para una baja real, sin UI todavía) -- sigue
  #   listada para trazabilidad, pero resolver_credencial/2 nunca la
  #   matchea.
  schema "meta_schema_consulta_endpoint_credencial" do
    field :nombre, :string
    field :api_key_hash, :string
    field :api_key_sufijo, :string
    field :campos_permitidos, {:array, :string}, default: []
    field :estado, :string, default: "activa"

    field :insert_guid, :string
    field :update_guid, :string
    field :delete_guid, :string

    belongs_to :endpoint, MetadataApp.MetaSchema.ConsultaEndpoint, foreign_key: :meta_schema_consulta_endpoint_id

    timestamps(type: :utc_datetime)
  end

  @estados ["activa", "revocada"]
  @requeridos [:meta_schema_consulta_endpoint_id, :nombre]

  @doc """
  `claves_visibles` -- claves namespaced (string) de los campos
  VISIBLES del endpoint (no de "es_parametro" -- ver moduledoc). Sin
  esa lista (changeset aislado en un test que no la necesita) la
  validación de R42 se omite.
  """
  def changeset(credencial, attrs, claves_visibles \\ nil) do
    credencial
    |> cast(attrs, @requeridos ++ [:campos_permitidos, :estado, :api_key_hash, :api_key_sufijo])
    |> validate_required(@requeridos ++ [:api_key_hash, :api_key_sufijo])
    |> validate_inclusion(:estado, @estados)
    |> validar_campos_permitidos(claves_visibles)
    |> foreign_key_constraint(:meta_schema_consulta_endpoint_id)
    |> unique_constraint(:api_key_hash)
  end

  defp validar_campos_permitidos(changeset, nil), do: changeset

  defp validar_campos_permitidos(changeset, claves_visibles) do
    visibles = MapSet.new(claves_visibles)
    permitidos = get_field(changeset, :campos_permitidos) || []
    invalidos = Enum.reject(permitidos, &MapSet.member?(visibles, &1))

    case invalidos do
      [] -> changeset
      campos -> add_error(changeset, :campos_permitidos, "no son campos visibles del endpoint: #{Enum.join(campos, ", ")}")
    end
  end
end
