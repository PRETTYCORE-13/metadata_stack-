defmodule MetadataApp.AutenticacionFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `MetadataApp.Autenticacion` context.
  """

  import Ecto.Query

  alias MetadataApp.Autenticacion
  alias MetadataApp.Autenticacion.Scope

  def unique_usuario_email, do: "usuario#{System.unique_integer()}@example.com"
  def valid_usuario_password, do: "hello world!"

  def valid_usuario_attributes(attrs \\ %{}) do
    Enum.into(attrs, %{
      email: unique_usuario_email()
    })
  end

  def unconfirmed_usuario_fixture(attrs \\ %{}) do
    {:ok, usuario} =
      attrs
      |> valid_usuario_attributes()
      |> Autenticacion.register_usuario()

    usuario
  end

  def usuario_fixture(attrs \\ %{}) do
    usuario = unconfirmed_usuario_fixture(attrs)

    token =
      extract_usuario_token(fn url ->
        Autenticacion.deliver_login_instructions(usuario, url)
      end)

    {:ok, {usuario, _expired_tokens}} =
      Autenticacion.login_usuario_by_magic_link(token)

    usuario
  end

  def usuario_scope_fixture do
    usuario = usuario_fixture()
    usuario_scope_fixture(usuario)
  end

  def usuario_scope_fixture(usuario) do
    Scope.for_usuario(usuario)
  end

  def set_password(usuario) do
    {:ok, {usuario, _expired_tokens}} =
      Autenticacion.update_usuario_password(usuario, %{password: valid_usuario_password()})

    usuario
  end

  def extract_usuario_token(fun) do
    {:ok, captured_email} = fun.(&"[TOKEN]#{&1}[TOKEN]")
    [_, token | _] = String.split(captured_email.text_body, "[TOKEN]")
    token
  end

  def override_token_authenticated_at(token, authenticated_at) when is_binary(token) do
    MetadataApp.Repo.update_all(
      from(t in Autenticacion.UsuarioToken,
        where: t.token == ^token
      ),
      set: [authenticated_at: authenticated_at]
    )
  end

  def generate_usuario_magic_link_token(usuario) do
    {encoded_token, usuario_token} = Autenticacion.UsuarioToken.build_email_token(usuario, "login")
    MetadataApp.Repo.insert!(usuario_token)
    {encoded_token, usuario_token.token}
  end

  def offset_usuario_token(token, amount_to_add, unit) do
    dt = DateTime.add(DateTime.utc_now(:second), amount_to_add, unit)

    MetadataApp.Repo.update_all(
      from(ut in Autenticacion.UsuarioToken, where: ut.token == ^token),
      set: [inserted_at: dt, authenticated_at: dt]
    )
  end
end
