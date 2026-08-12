defmodule MetadataApp.Autenticacion.Usuario do
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{
          id: integer() | nil,
          email: String.t() | nil,
          alias: String.t() | nil,
          avatar_seed: String.t() | nil,
          hashed_password: String.t() | nil,
          confirmed_at: DateTime.t() | nil,
          super_admin: boolean()
        }

  schema "meta_schema_usuario" do
    field :email, :string
    field :alias, :string
    field :avatar_seed, :string
    field :password, :string, virtual: true, redact: true
    field :hashed_password, :string, redact: true
    field :confirmed_at, :utc_datetime
    field :authenticated_at, :utc_datetime, virtual: true
    # Cross-empresa, fuera del RBAC normal (que siempre gira alrededor de
    # una empresa activa) — desbloquea ÚNICAMENTE ver/crear/unirse a
    # CUALQUIER empresa (EmpresasLive), nada de saltar permisos de
    # catálogos dentro de cada tenant. No es un rol de meta_schema_rol a
    # propósito: ese modelo asume {usuario, rol, empresa}, y esto es
    # deliberadamente independiente de cualquier empresa.
    field :super_admin, :boolean, default: false

    # Jerarquía operativa activa -- "default" de Empresa (2026-08-12):
    # cuál de las N empresas a las que pertenece este usuario el login
    # elige sola, sin mandarlo a /seleccionar-empresa (ver
    # UsuarioAuth.log_in_usuario/2). Mismo concepto que branch_default_id
    # etc. en UsuarioEmpresa, pero acá porque este default es CROSS-
    # empresa (dice cuál FILA de membresía es la default entre varias),
    # no un dato de adentro de una sola empresa.
    belongs_to :empresa_default, MetadataApp.Autenticacion.Empresa

    timestamps(type: :utc_datetime)
  end

  @doc "Changeset para que el usuario elija/cambie su alias — nunca requerido, a diferencia del email."
  def alias_changeset(usuario, attrs) do
    usuario
    |> cast(attrs, [:alias])
    |> validate_length(:alias, max: 40)
  end

  @doc "Cambia SOLO el default de empresa -- separado de alias_changeset/2, mismo criterio que UsuarioEmpresa.changeset_default/2."
  def changeset_empresa_default(usuario, attrs) do
    cast(usuario, attrs, [:empresa_default_id])
  end

  @doc """
  Nombre para mostrar en la UI: el alias si lo tiene, si no la parte del
  email antes de la @ — nunca nil ni vacío mientras haya un usuario real.
  """
  def nombre_mostrar(%__MODULE__{alias: alias_, email: email}) do
    case alias_ do
      nil -> email |> String.split("@") |> hd()
      "" -> email |> String.split("@") |> hd()
      valor -> valor
    end
  end

  @doc "Changeset para que el usuario elija su avatar (semilla de DiceBear) — nunca requerido."
  def avatar_changeset(usuario, attrs) do
    usuario
    |> cast(attrs, [:avatar_seed])
    |> validate_length(:avatar_seed, max: 100)
  end

  @avatar_estilo "critters"

  @doc """
  URL del avatar del usuario (DiceBear, SVG) — usa `avatar_seed` si lo
  eligió, si no el email como semilla determinística (mismo usuario
  siempre da el mismo avatar por default, sin elegir nada).
  """
  def avatar_url(%__MODULE__{avatar_seed: seed, email: email}, size \\ 64) do
    avatar_url_desde_semilla(seed || email, size)
  end

  @doc "URL de avatar para una semilla cualquiera — usado también por el selector (opciones sin guardar todavía)."
  def avatar_url_desde_semilla(semilla, size \\ 64) do
    "https://api.dicebear.com/10.x/#{@avatar_estilo}/svg?seed=#{URI.encode_www_form(to_string(semilla))}&size=#{size}"
  end

  @doc "N semillas al azar para mostrar como opciones en el selector de avatar."
  def semillas_avatar_al_azar(cantidad \\ 8) do
    for _ <- 1..cantidad, do: Ecto.UUID.generate()
  end

  @doc """
  A usuario changeset for registering or changing the email.

  It requires the email to change otherwise an error is added.

  ## Options

    * `:validate_unique` - Set to false if you don't want to validate the
      uniqueness of the email, useful when displaying live validations.
      Defaults to `true`.
  """
  def email_changeset(usuario, attrs, opts \\ []) do
    usuario
    |> cast(attrs, [:email])
    |> validate_email(opts)
  end

  defp validate_email(changeset, opts) do
    changeset =
      changeset
      |> validate_required([:email])
      |> validate_format(:email, ~r/^[^@,;\s]+@[^@,;\s]+$/,
        message: "must have the @ sign and no spaces"
      )
      |> validate_length(:email, max: 160)

    if Keyword.get(opts, :validate_unique, true) do
      changeset
      |> unsafe_validate_unique(:email, MetadataApp.Repo)
      |> unique_constraint(:email)
      |> validate_email_changed()
    else
      changeset
    end
  end

  defp validate_email_changed(changeset) do
    if get_field(changeset, :email) && get_change(changeset, :email) == nil do
      add_error(changeset, :email, "did not change")
    else
      changeset
    end
  end

  @doc """
  A usuario changeset for changing the password.

  It is important to validate the length of the password, as long passwords may
  be very expensive to hash for certain algorithms.

  ## Options

    * `:hash_password` - Hashes the password so it can be stored securely
      in the database and ensures the password field is cleared to prevent
      leaks in the logs. If password hashing is not needed and clearing the
      password field is not desired (like when using this changeset for
      validations on a LiveView form), this option can be set to `false`.
      Defaults to `true`.
  """
  def password_changeset(usuario, attrs, opts \\ []) do
    usuario
    |> cast(attrs, [:password])
    |> validate_confirmation(:password, message: "does not match password")
    |> validate_password(opts)
  end

  defp validate_password(changeset, opts) do
    changeset
    |> validate_required([:password])
    |> validate_length(:password, min: 12, max: 72)
    # Examples of additional password validation:
    # |> validate_format(:password, ~r/[a-z]/, message: "at least one lower case character")
    # |> validate_format(:password, ~r/[A-Z]/, message: "at least one upper case character")
    # |> validate_format(:password, ~r/[!?@#$%^&*_0-9]/, message: "at least one digit or punctuation character")
    |> maybe_hash_password(opts)
  end

  defp maybe_hash_password(changeset, opts) do
    hash_password? = Keyword.get(opts, :hash_password, true)
    password = get_change(changeset, :password)

    if hash_password? && password && changeset.valid? do
      changeset
      # Hashing could be done with `Ecto.Changeset.prepare_changes/2`, but that
      # would keep the database transaction open longer and hurt performance.
      |> put_change(:hashed_password, Pbkdf2.hash_pwd_salt(password))
      |> delete_change(:password)
    else
      changeset
    end
  end

  @doc """
  Confirms the account by setting `confirmed_at`.
  """
  def confirm_changeset(usuario) do
    now = DateTime.utc_now(:second)
    change(usuario, confirmed_at: now)
  end

  @doc """
  Verifies the password.

  If there is no usuario or the usuario doesn't have a password, we call
  `Pbkdf2.no_user_verify/0` to avoid timing attacks.
  """
  def valid_password?(%MetadataApp.Autenticacion.Usuario{hashed_password: hashed_password}, password)
      when is_binary(hashed_password) and byte_size(password) > 0 do
    Pbkdf2.verify_pass(password, hashed_password)
  end

  def valid_password?(_, _) do
    Pbkdf2.no_user_verify()
    false
  end
end
