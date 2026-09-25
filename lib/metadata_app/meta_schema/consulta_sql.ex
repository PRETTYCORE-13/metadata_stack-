defmodule MetadataApp.MetaSchema.ConsultaSql do
  use Ecto.Schema
  import Ecto.Changeset

  # Un registro = la definición de un BC tipo "Consulta SQL"
  # (schema_context_type: 4 en su Header, SPEC-SYS-2509202601). El SQL se
  # convierte en una vista de Postgres con el mismo nombre que el Header
  # (ver MetadataApp.ConsultasSql); acá solo vive su definición.
  #
  #   uso             -- "diccionario" | "consulta"
  #   sql             -- el SQL tal cual lo pegó el admin (nil hasta el
  #                      primer guardado)
  #   columnas        -- [%{"nombre" =>, "tipo" =>}] detectadas al guardar
  #   bcs_autorizados -- nombres de catálogo que pueden elegir este
  #                      Diccionario en sus campos referencia
  @usos ~w(diccionario consulta)

  schema "meta_schema_consulta_sql" do
    field :uso, :string, default: "diccionario"
    field :sql, :string
    field :columnas, {:array, :map}, default: []
    field :bcs_autorizados, {:array, :string}, default: []

    field :insert_guid, :string
    field :update_guid, :string
    field :delete_guid, :string

    belongs_to :header, MetadataApp.BusinessProcessBuilder.MetaSchema.Header, foreign_key: :meta_schema_header_id

    timestamps(type: :utc_datetime)
  end

  def usos, do: @usos

  def changeset(consulta_sql, attrs) do
    consulta_sql
    |> cast(attrs, [:meta_schema_header_id, :uso, :sql, :columnas, :bcs_autorizados])
    |> validate_required([:meta_schema_header_id, :uso])
    |> validate_inclusion(:uso, @usos, message: "tiene que ser Diccionario o Consulta")
    |> unique_constraint([:meta_schema_header_id])
    |> foreign_key_constraint(:meta_schema_header_id)
  end
end
