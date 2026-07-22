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

    # PrettyCore TRN (Transaction Reference Number) — separado a propósito
    # de schema_context_type (que ya usa 2 para "carpeta", una dimensión
    # distinta a "es transaccional"). codigo_trn (ej. "VENT") solo es
    # obligatorio cuando schema_es_transaccional: true — ver changeset/2.
    field :schema_es_transaccional, :boolean, default: false
    field :codigo_trn, :string

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
    |> cast(attrs, @requeridos ++ [:schema_context_icono, :schema_set_permissions, :schema_profiles, :schema_es_transaccional, :codigo_trn])
    |> validate_required(@requeridos)
    |> update_change(:codigo_trn, &nil_si_vacio_o_mayusculas/1)
    |> validar_codigo_trn()
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
end
