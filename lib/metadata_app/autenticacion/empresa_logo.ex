defmodule MetadataApp.Autenticacion.EmpresaLogo do
  @moduledoc """
  Logo de una empresa (una fila por empresa). El binario vive aquí y no en
  `Empresa` para que hidratar el scope en cada request no lo cargue; la
  top bar solo necesita `Empresa.logo_version`. Lo escribe únicamente
  `Autenticacion.guardar_logo_empresa/2`, ya validado por `ImagenLogo`.
  """

  use Ecto.Schema

  schema "meta_schema_empresa_logo" do
    belongs_to :empresa, MetadataApp.Autenticacion.Empresa

    field :contenido, :binary
    field :content_type, :string
    field :ancho, :integer
    field :alto, :integer
    field :tamano_bytes, :integer
    field :hash, :string

    timestamps(type: :utc_datetime)
  end
end
