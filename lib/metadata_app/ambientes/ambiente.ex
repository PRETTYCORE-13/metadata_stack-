defmodule MetadataApp.Ambientes.Ambiente do
  use Ecto.Schema
  import Ecto.Changeset

  schema "meta_schema_ambiente_deploy" do
    field :nombre, :string
    field :host, :string
    field :ssh_usuario, :string
    field :ssh_password, MetadataApp.Encriptado
    field :ssh_llave_privada, MetadataApp.Encriptado
    field :docker_servicio, :string, default: "metadata_stack_app"
    field :imagen_docker, :string, default: "ghcr.io/prettycore-13/metadata_stack:latest"

    # Virtuales -- mismo criterio que Credencial.api_key_nuevo: nunca se
    # persisten, son el ÚNICO canal de entrada para el secreto real.
    # Vacío/ausente = no tocar lo ya guardado, así el form de edición
    # siempre puede mostrarse en blanco sin borrar la credencial existente
    # con solo abrir y guardar.
    field :ssh_password_nuevo, :string, virtual: true
    field :ssh_llave_privada_nueva, :string, virtual: true

    field :insert_guid, :string
    field :update_guid, :string
    field :delete_guid, :string

    timestamps(type: :utc_datetime)
  end

  @doc "Alta -- exige host/usuario y AL MENOS una credencial (clave o contraseña)."
  def changeset_creacion(ambiente, attrs) do
    ambiente
    |> cast(attrs, [:nombre, :host, :ssh_usuario, :ssh_password_nuevo, :ssh_llave_privada_nueva, :docker_servicio, :imagen_docker])
    |> validate_required([:nombre, :host, :ssh_usuario])
    |> aplicar_secretos_nuevos()
    |> validar_alguna_credencial()
  end

  @doc "Edición -- las credenciales son opcionales; vacías = no tocar lo ya guardado."
  def changeset_edicion(ambiente, attrs) do
    ambiente
    |> cast(attrs, [:nombre, :host, :ssh_usuario, :ssh_password_nuevo, :ssh_llave_privada_nueva, :docker_servicio, :imagen_docker])
    |> validate_required([:nombre, :host, :ssh_usuario])
    |> aplicar_secretos_nuevos()
    |> validar_alguna_credencial()
  end

  @doc """
  Quita la llave privada guardada -- único camino explícito para esto. El
  form normal (changeset_edicion/2) NUNCA lo hace a propósito: dejar el
  campo en blanco significa "no tocar lo ya guardado" (ver
  aplicar_secreto_nuevo/3), no "borrarlo". Encontrado real (2026-08-27):
  una llave pegada mal formada ("invalid format" de ssh) queda sin forma
  de sacarla si el ambiente también tiene contraseña -- este changeset es
  el escape hatch para ese caso.
  """
  def changeset_quitar_llave(ambiente) do
    ambiente
    |> change(%{ssh_llave_privada: nil})
    |> validar_alguna_credencial()
  end

  defp aplicar_secretos_nuevos(changeset) do
    changeset
    |> aplicar_secreto_nuevo(:ssh_password_nuevo, :ssh_password)
    |> aplicar_secreto_nuevo(:ssh_llave_privada_nueva, :ssh_llave_privada)
  end

  defp aplicar_secreto_nuevo(changeset, campo_nuevo, campo_real) do
    case get_change(changeset, campo_nuevo) do
      valor when valor in [nil, ""] -> changeset
      nuevo -> put_change(changeset, campo_real, nuevo)
    end
  end

  # mix motor.desplegar necesita AL MENOS una forma de autenticar -- ni el
  # form de alta ni el de edición dejan guardar un ambiente sin ninguna,
  # lo que sería un ambiente inútil (nadie podría desplegar ahí).
  defp validar_alguna_credencial(changeset) do
    tiene_password? = get_field(changeset, :ssh_password) not in [nil, ""]
    tiene_llave? = get_field(changeset, :ssh_llave_privada) not in [nil, ""]

    if tiene_password? or tiene_llave? do
      changeset
    else
      add_error(changeset, :ssh_password_nuevo, "necesita contraseña o llave privada")
    end
  end
end
