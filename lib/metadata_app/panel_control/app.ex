defmodule MetadataApp.PanelControl.App do
  use Ecto.Schema
  import Ecto.Changeset

  schema "meta_schema_panel_control_app" do
    field :nombre, :string
    field :subdominio, :string
    field :dominio_base, :string
    field :imagen_docker, :string
    field :puerto_interno, :integer
    field :variables_entorno, :map, default: %{}
    field :nodeport, :integer
    field :estado, :string, default: "pendiente"
    field :ultimo_error, :string

    belongs_to :ambiente, MetadataApp.Ambientes.Ambiente

    field :insert_guid, :string
    field :update_guid, :string
    field :delete_guid, :string

    timestamps(type: :utc_datetime)
  end

  @doc "Alta -- todo lo que Desplegador.crear_app/1 necesita para arrancar el despliegue."
  def changeset_creacion(app, attrs) do
    app
    |> cast(attrs, [:nombre, :subdominio, :dominio_base, :imagen_docker, :puerto_interno, :variables_entorno, :ambiente_id])
    |> validate_required([:nombre, :subdominio, :dominio_base, :imagen_docker, :puerto_interno, :ambiente_id])
    |> validate_format(:subdominio, ~r/^[a-z0-9-]+$/, message: "solo minúsculas, números y guiones")
    |> validate_number(:puerto_interno, greater_than: 0, less_than: 65536)
    |> foreign_key_constraint(:ambiente_id)
    |> unique_constraint([:subdominio, :dominio_base], message: "ya existe una app con este subdominio+dominio")
  end

  @doc "Actualiza estado/nodeport/error -- usado por Desplegador a medida que avanza el despliegue, nunca desde un formulario."
  def changeset_estado(app, attrs) do
    cast(app, attrs, [:estado, :nodeport, :ultimo_error])
  end
end
