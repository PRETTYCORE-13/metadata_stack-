defmodule MetadataApp.Autenticacion do
  @moduledoc """
  The Autenticacion context.
  """

  import Ecto.Query, warn: false
  alias MetadataApp.Repo

  alias MetadataApp.Autenticacion.{Usuario, UsuarioToken, UsuarioNotifier, Empresa, UsuarioEmpresa, UsuarioRol, Rol}

  ## Empresas (tenant) del usuario — un usuario puede tener varias; la que
  ## use en un momento dado queda en el Scope (`empresa_activa`), elegida
  ## por un selector post-login cuando tiene más de una.

  @doc "Lista las empresas a las que un usuario tiene acceso, ordenadas por nombre."
  def empresas_de_usuario(usuario_id) do
    from(e in Empresa,
      join: ue in UsuarioEmpresa,
      on: ue.empresa_id == e.id and is_nil(ue.delete_guid),
      where: ue.usuario_id == ^usuario_id and is_nil(e.delete_guid),
      order_by: e.nombre
    )
    |> Repo.all()
  end

  @doc "Confirma que el usuario tiene acceso a esa empresa antes de activarla en el Scope."
  def obtener_empresa_de_usuario(usuario_id, empresa_id) do
    from(e in Empresa,
      join: ue in UsuarioEmpresa,
      on: ue.empresa_id == e.id and is_nil(ue.delete_guid),
      where: ue.usuario_id == ^usuario_id and e.id == ^empresa_id and is_nil(e.delete_guid)
    )
    |> Repo.one()
  end

  @doc """
  Crea una empresa nueva y deja al usuario creador como miembro +
  `administrador` ahí, todo en la misma transacción — si no, quedaría un
  tenant al que ni el creador podría entrar después (no hay todavía un
  "super admin" cross-empresa que pueda rescatarlo).
  """
  def crear_empresa_para_usuario(nombre, usuario_id) do
    Repo.transaction(fn ->
      with {:ok, empresa} <-
             %Empresa{}
             |> Empresa.changeset(%{nombre: nombre})
             |> Ecto.Changeset.change(%{insert_guid: generar_guid()})
             |> Repo.insert(),
           {:ok, _} <-
             %UsuarioEmpresa{}
             |> UsuarioEmpresa.changeset(%{usuario_id: usuario_id, empresa_id: empresa.id})
             |> Ecto.Changeset.change(%{insert_guid: generar_guid()})
             |> Repo.insert(),
           rol_admin <- Repo.get_by!(Rol, nombre: "administrador"),
           {:ok, _} <- MetadataApp.Permissions.asignar_rol(usuario_id, rol_admin.id, empresa.id) do
        empresa
      else
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  @doc "Solo el nombre por ahora — crear/editar más campos de empresa queda para cuando haga falta."
  def actualizar_empresa(empresa, attrs) do
    empresa
    |> Empresa.changeset(attrs)
    |> Ecto.Changeset.change(%{update_guid: generar_guid()})
    |> Repo.update()
  end

  defp generar_guid do
    Ecto.UUID.generate() |> String.replace("-", "")
  end

  @doc "Usuarios que pertenecen a una empresa, con si su cuenta ya está confirmada."
  def listar_usuarios_de_empresa(empresa_id) do
    from(u in Usuario,
      join: ue in UsuarioEmpresa,
      on: ue.usuario_id == u.id and is_nil(ue.delete_guid),
      where: ue.empresa_id == ^empresa_id,
      order_by: u.email
    )
    |> Repo.all()
  end

  @doc """
  Agrega un usuario a una empresa por email — unifica "agregar a alguien
  que ya tiene cuenta" e "invitar a alguien nuevo" en una sola acción (no
  hay flujo de invitación por email separado todavía: si la cuenta no
  existe, se crea sin contraseña, lista para el login por magic link igual
  que cualquier otra). Es un no-op silencioso si ya era miembro.
  """
  def agregar_usuario_a_empresa(email, empresa_id) do
    usuario =
      case get_usuario_by_email(email) do
        nil ->
          {:ok, usuario} = register_usuario(%{email: email})
          usuario

        usuario ->
          usuario
      end

    case obtener_empresa_de_usuario(usuario.id, empresa_id) do
      nil ->
        %UsuarioEmpresa{}
        |> UsuarioEmpresa.changeset(%{usuario_id: usuario.id, empresa_id: empresa_id})
        |> Repo.insert()

      _ya_miembro ->
        {:ok, usuario}
    end
  end

  @doc """
  Quita a un usuario de una empresa (soft-delete) y revoca cualquier rol
  que tuviera asignado EN ESA empresa — un rol atado a una empresa de la
  que ya no es miembro queda huérfano (ni siquiera podría volver a elegir
  esa empresa para usarlo).
  """
  def remover_usuario_de_empresa(usuario_id, empresa_id) do
    from(ur in UsuarioRol,
      where: ur.usuario_id == ^usuario_id and ur.empresa_id == ^empresa_id and is_nil(ur.delete_guid),
      select: ur.rol_id
    )
    |> Repo.all()
    |> Enum.each(&MetadataApp.Permissions.revocar_rol(usuario_id, &1, empresa_id))

    case Repo.get_by(UsuarioEmpresa, usuario_id: usuario_id, empresa_id: empresa_id) do
      nil ->
        {:error, :no_encontrado}

      usuario_empresa ->
        usuario_empresa
        |> Ecto.Changeset.change(%{delete_guid: Ecto.UUID.generate() |> String.replace("-", "")})
        |> Repo.update()
    end
  end

  ## Database getters

  @doc """
  Gets a usuario by email.

  ## Examples

      iex> get_usuario_by_email("foo@example.com")
      %Usuario{}

      iex> get_usuario_by_email("unknown@example.com")
      nil

  """
  def get_usuario_by_email(email) when is_binary(email) do
    Repo.get_by(Usuario, email: email)
  end

  @doc """
  Gets a usuario by email and password.

  ## Examples

      iex> get_usuario_by_email_and_password("foo@example.com", "correct_password")
      %Usuario{}

      iex> get_usuario_by_email_and_password("foo@example.com", "invalid_password")
      nil

  """
  def get_usuario_by_email_and_password(email, password)
      when is_binary(email) and is_binary(password) do
    usuario = Repo.get_by(Usuario, email: email)
    if Usuario.valid_password?(usuario, password), do: usuario
  end

  @doc """
  Gets a single usuario.

  Raises `Ecto.NoResultsError` if the Usuario does not exist.

  ## Examples

      iex> get_usuario!(123)
      %Usuario{}

      iex> get_usuario!(456)
      ** (Ecto.NoResultsError)

  """
  def get_usuario!(id), do: Repo.get!(Usuario, id)

  ## Usuario registration

  @doc """
  Registers a usuario.

  ## Examples

      iex> register_usuario(%{field: value})
      {:ok, %Usuario{}}

      iex> register_usuario(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def register_usuario(attrs) do
    %Usuario{}
    |> Usuario.email_changeset(attrs)
    |> Repo.insert()
  end

  ## Settings

  @doc """
  Checks whether the usuario is in sudo mode.

  The usuario is in sudo mode when the last authentication was done no further
  than 20 minutes ago. The limit can be given as second argument in minutes.
  """
  def sudo_mode?(usuario, minutes \\ -20)

  def sudo_mode?(%Usuario{authenticated_at: ts}, minutes) when is_struct(ts, DateTime) do
    DateTime.after?(ts, DateTime.utc_now() |> DateTime.add(minutes, :minute))
  end

  def sudo_mode?(_usuario, _minutes), do: false

  @doc """
  Returns an `%Ecto.Changeset{}` for changing the usuario email.

  See `MetadataApp.Autenticacion.Usuario.email_changeset/3` for a list of supported options.

  ## Examples

      iex> change_usuario_email(usuario)
      %Ecto.Changeset{data: %Usuario{}}

  """
  def change_usuario_email(usuario, attrs \\ %{}, opts \\ []) do
    Usuario.email_changeset(usuario, attrs, opts)
  end

  @doc """
  Updates the usuario email using the given token.

  If the token matches, the usuario email is updated and the token is deleted.
  """
  def update_usuario_email(usuario, token) do
    context = "change:#{usuario.email}"

    Repo.transact(fn ->
      with {:ok, query} <- UsuarioToken.verify_change_email_token_query(token, context),
           %UsuarioToken{sent_to: email} <- Repo.one(query),
           {:ok, usuario} <- Repo.update(Usuario.email_changeset(usuario, %{email: email})),
           {_count, _result} <-
             Repo.delete_all(from(UsuarioToken, where: [usuario_id: ^usuario.id, context: ^context])) do
        {:ok, usuario}
      else
        _ -> {:error, :transaction_aborted}
      end
    end)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for changing the usuario password.

  See `MetadataApp.Autenticacion.Usuario.password_changeset/3` for a list of supported options.

  ## Examples

      iex> change_usuario_password(usuario)
      %Ecto.Changeset{data: %Usuario{}}

  """
  def change_usuario_password(usuario, attrs \\ %{}, opts \\ []) do
    Usuario.password_changeset(usuario, attrs, opts)
  end

  @doc """
  Updates the usuario password.

  Returns a tuple with the updated usuario, as well as a list of expired tokens.

  ## Examples

      iex> update_usuario_password(usuario, %{password: ...})
      {:ok, {%Usuario{}, [...]}}

      iex> update_usuario_password(usuario, %{password: "too short"})
      {:error, %Ecto.Changeset{}}

  """
  def update_usuario_password(usuario, attrs) do
    usuario
    |> Usuario.password_changeset(attrs)
    |> update_usuario_and_delete_all_tokens()
  end

  ## Session

  @doc """
  Generates a session token.
  """
  def generate_usuario_session_token(usuario) do
    {token, usuario_token} = UsuarioToken.build_session_token(usuario)
    Repo.insert!(usuario_token)
    token
  end

  @doc """
  Gets the usuario with the given signed token.

  If the token is valid `{usuario, token_inserted_at}` is returned, otherwise `nil` is returned.
  """
  def get_usuario_by_session_token(token) do
    {:ok, query} = UsuarioToken.verify_session_token_query(token)
    Repo.one(query)
  end

  @doc """
  Gets the usuario with the given magic link token.
  """
  def get_usuario_by_magic_link_token(token) do
    with {:ok, query} <- UsuarioToken.verify_magic_link_token_query(token),
         {usuario, _token} <- Repo.one(query) do
      usuario
    else
      _ -> nil
    end
  end

  @doc """
  Logs the usuario in by magic link.

  There are three cases to consider:

  1. The usuario has already confirmed their email. They are logged in
     and the magic link is expired.

  2. The usuario has not confirmed their email and no password is set.
     In this case, the usuario gets confirmed, logged in, and all tokens -
     including session ones - are expired. In theory, no other tokens
     exist but we delete all of them for best security practices.

  3. The usuario has not confirmed their email but a password is set.
     This cannot happen in the default implementation but may be the
     source of security pitfalls. See the "Mixing magic link and password registration" section of
     `mix help phx.gen.auth`.
  """
  def login_usuario_by_magic_link(token) do
    {:ok, query} = UsuarioToken.verify_magic_link_token_query(token)

    case Repo.one(query) do
      # Prevent session fixation attacks by disallowing magic links for unconfirmed users with password
      {%Usuario{confirmed_at: nil, hashed_password: hash}, _token} when not is_nil(hash) ->
        raise """
        magic link log in is not allowed for unconfirmed users with a password set!

        This cannot happen with the default implementation, which indicates that you
        might have adapted the code to a different use case. Please make sure to read the
        "Mixing magic link and password registration" section of `mix help phx.gen.auth`.
        """

      {%Usuario{confirmed_at: nil} = usuario, _token} ->
        usuario
        |> Usuario.confirm_changeset()
        |> update_usuario_and_delete_all_tokens()

      {usuario, token} ->
        Repo.delete!(token)
        {:ok, {usuario, []}}

      nil ->
        {:error, :not_found}
    end
  end

  @doc ~S"""
  Delivers the update email instructions to the given usuario.

  ## Examples

      iex> deliver_usuario_update_email_instructions(usuario, current_email, &url(~p"/meta_schema_usuario/settings/confirm-email/#{&1}"))
      {:ok, %{to: ..., body: ...}}

  """
  def deliver_usuario_update_email_instructions(%Usuario{} = usuario, current_email, update_email_url_fun)
      when is_function(update_email_url_fun, 1) do
    {encoded_token, usuario_token} = UsuarioToken.build_email_token(usuario, "change:#{current_email}")

    Repo.insert!(usuario_token)
    UsuarioNotifier.deliver_update_email_instructions(usuario, update_email_url_fun.(encoded_token))
  end

  @doc """
  Delivers the magic link login instructions to the given usuario.
  """
  def deliver_login_instructions(%Usuario{} = usuario, magic_link_url_fun)
      when is_function(magic_link_url_fun, 1) do
    {encoded_token, usuario_token} = UsuarioToken.build_email_token(usuario, "login")
    Repo.insert!(usuario_token)
    UsuarioNotifier.deliver_login_instructions(usuario, magic_link_url_fun.(encoded_token))
  end

  @doc """
  Deletes the signed token with the given context.
  """
  def delete_usuario_session_token(token) do
    Repo.delete_all(from(UsuarioToken, where: [token: ^token, context: "session"]))
    :ok
  end

  ## Token helper

  defp update_usuario_and_delete_all_tokens(changeset) do
    Repo.transact(fn ->
      with {:ok, usuario} <- Repo.update(changeset) do
        tokens_to_expire = Repo.all_by(UsuarioToken, usuario_id: usuario.id)

        Repo.delete_all(from(t in UsuarioToken, where: t.id in ^Enum.map(tokens_to_expire, & &1.id)))

        {:ok, {usuario, tokens_to_expire}}
      end
    end)
  end
end
