defmodule MetadataApp.Integraciones.Credencial do
  use Ecto.Schema
  import Ecto.Changeset

  schema "meta_schema_credencial" do
    field :nombre, :string
    field :sistema_externo, :string
    field :api_key, MetadataApp.Encriptado
    field :base_url, :string

    field :ultima_ejecucion_en, :utc_datetime
    field :ultimo_error, :string

    # Virtual -- nunca se persiste, es el ÚNICO canal de entrada para la key
    # real (ver aplicar_api_key_nuevo/1 abajo). Vacío/ausente = no tocar la
    # key ya guardada -- así el formulario de edición SIEMPRE puede
    # mostrarse en blanco (nunca precargado con el valor descifrado) sin
    # que dejarlo así borre la credencial existente.
    field :api_key_nuevo, :string, virtual: true

    field :insert_guid, :string
    field :update_guid, :string
    field :delete_guid, :string

    timestamps(type: :utc_datetime)
  end

  @doc "Alta -- acá api_key_nuevo SÍ es obligatorio, no hay nada previo que conservar."
  def changeset_creacion(credencial, attrs) do
    credencial
    |> cast(attrs, [:nombre, :sistema_externo, :api_key_nuevo, :base_url])
    |> validate_required([:nombre, :api_key_nuevo])
    |> aplicar_api_key_nuevo()
  end

  @doc "Edición -- api_key_nuevo es opcional; vacío = no tocar la key ya guardada."
  def changeset_edicion(credencial, attrs) do
    credencial
    |> cast(attrs, [:nombre, :sistema_externo, :api_key_nuevo, :base_url])
    |> validate_required([:nombre])
    |> aplicar_api_key_nuevo()
  end

  defp aplicar_api_key_nuevo(changeset) do
    case get_change(changeset, :api_key_nuevo) do
      valor when valor in [nil, ""] -> changeset
      nueva -> put_change(changeset, :api_key, nueva)
    end
  end
end
