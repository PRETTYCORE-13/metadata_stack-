defmodule MetadataApp.AutenticacionTest do
  use MetadataApp.DataCase

  alias MetadataApp.Autenticacion

  import MetadataApp.AutenticacionFixtures
  alias MetadataApp.Autenticacion.{Usuario, UsuarioToken}

  describe "get_usuario_by_email/1" do
    test "does not return the usuario if the email does not exist" do
      refute Autenticacion.get_usuario_by_email("unknown@example.com")
    end

    test "returns the usuario if the email exists" do
      %{id: id} = usuario = usuario_fixture()
      assert %Usuario{id: ^id} = Autenticacion.get_usuario_by_email(usuario.email)
    end
  end

  describe "get_usuario_by_email_and_password/2" do
    test "does not return the usuario if the email does not exist" do
      refute Autenticacion.get_usuario_by_email_and_password("unknown@example.com", "hello world!")
    end

    test "does not return the usuario if the password is not valid" do
      usuario = usuario_fixture() |> set_password()
      refute Autenticacion.get_usuario_by_email_and_password(usuario.email, "invalid")
    end

    test "returns the usuario if the email and password are valid" do
      %{id: id} = usuario = usuario_fixture() |> set_password()

      assert %Usuario{id: ^id} =
               Autenticacion.get_usuario_by_email_and_password(usuario.email, valid_usuario_password())
    end
  end

  describe "get_usuario!/1" do
    test "raises if id is invalid" do
      assert_raise Ecto.NoResultsError, fn ->
        Autenticacion.get_usuario!(-1)
      end
    end

    test "returns the usuario with the given id" do
      %{id: id} = usuario = usuario_fixture()
      assert %Usuario{id: ^id} = Autenticacion.get_usuario!(usuario.id)
    end
  end

  describe "register_usuario/1" do
    test "requires email to be set" do
      {:error, changeset} = Autenticacion.register_usuario(%{})

      assert %{email: ["can't be blank"]} = errors_on(changeset)
    end

    test "validates email when given" do
      {:error, changeset} = Autenticacion.register_usuario(%{email: "not valid"})

      assert %{email: ["must have the @ sign and no spaces"]} = errors_on(changeset)
    end

    test "validates maximum values for email for security" do
      too_long = String.duplicate("db", 100)
      {:error, changeset} = Autenticacion.register_usuario(%{email: too_long})
      assert "should be at most 160 character(s)" in errors_on(changeset).email
    end

    test "validates email uniqueness" do
      %{email: email} = usuario_fixture()
      {:error, changeset} = Autenticacion.register_usuario(%{email: email})
      assert "has already been taken" in errors_on(changeset).email

      # Now try with the uppercased email too, to check that email case is ignored.
      {:error, changeset} = Autenticacion.register_usuario(%{email: String.upcase(email)})
      assert "has already been taken" in errors_on(changeset).email
    end

    test "registers meta_schema_usuario without password" do
      email = unique_usuario_email()
      {:ok, usuario} = Autenticacion.register_usuario(valid_usuario_attributes(email: email))
      assert usuario.email == email
      assert is_nil(usuario.hashed_password)
      assert is_nil(usuario.confirmed_at)
      assert is_nil(usuario.password)
    end
  end

  describe "sudo_mode?/2" do
    test "validates the authenticated_at time" do
      now = DateTime.utc_now()

      assert Autenticacion.sudo_mode?(%Usuario{authenticated_at: DateTime.utc_now()})
      assert Autenticacion.sudo_mode?(%Usuario{authenticated_at: DateTime.add(now, -19, :minute)})
      refute Autenticacion.sudo_mode?(%Usuario{authenticated_at: DateTime.add(now, -21, :minute)})

      # minute override
      refute Autenticacion.sudo_mode?(
               %Usuario{authenticated_at: DateTime.add(now, -11, :minute)},
               -10
             )

      # not authenticated
      refute Autenticacion.sudo_mode?(%Usuario{})
    end
  end

  describe "change_usuario_email/3" do
    test "returns a usuario changeset" do
      assert %Ecto.Changeset{} = changeset = Autenticacion.change_usuario_email(%Usuario{})
      assert changeset.required == [:email]
    end
  end

  describe "deliver_usuario_update_email_instructions/3" do
    setup do
      %{usuario: usuario_fixture()}
    end

    test "sends token through notification", %{usuario: usuario} do
      token =
        extract_usuario_token(fn url ->
          Autenticacion.deliver_usuario_update_email_instructions(usuario, "current@example.com", url)
        end)

      {:ok, token} = Base.url_decode64(token, padding: false)
      assert usuario_token = Repo.get_by(UsuarioToken, token: :crypto.hash(:sha256, token))
      assert usuario_token.usuario_id == usuario.id
      assert usuario_token.sent_to == usuario.email
      assert usuario_token.context == "change:current@example.com"
    end
  end

  describe "update_usuario_email/2" do
    setup do
      usuario = unconfirmed_usuario_fixture()
      email = unique_usuario_email()

      token =
        extract_usuario_token(fn url ->
          Autenticacion.deliver_usuario_update_email_instructions(%{usuario | email: email}, usuario.email, url)
        end)

      %{usuario: usuario, token: token, email: email}
    end

    test "updates the email with a valid token", %{usuario: usuario, token: token, email: email} do
      assert {:ok, %{email: ^email}} = Autenticacion.update_usuario_email(usuario, token)
      changed_usuario = Repo.get!(Usuario, usuario.id)
      assert changed_usuario.email != usuario.email
      assert changed_usuario.email == email
      refute Repo.get_by(UsuarioToken, usuario_id: usuario.id)
    end

    test "does not update email with invalid token", %{usuario: usuario} do
      assert Autenticacion.update_usuario_email(usuario, "oops") ==
               {:error, :transaction_aborted}

      assert Repo.get!(Usuario, usuario.id).email == usuario.email
      assert Repo.get_by(UsuarioToken, usuario_id: usuario.id)
    end

    test "does not update email if usuario email changed", %{usuario: usuario, token: token} do
      assert Autenticacion.update_usuario_email(%{usuario | email: "current@example.com"}, token) ==
               {:error, :transaction_aborted}

      assert Repo.get!(Usuario, usuario.id).email == usuario.email
      assert Repo.get_by(UsuarioToken, usuario_id: usuario.id)
    end

    test "does not update email if token expired", %{usuario: usuario, token: token} do
      {1, nil} = Repo.update_all(UsuarioToken, set: [inserted_at: ~N[2020-01-01 00:00:00]])

      assert Autenticacion.update_usuario_email(usuario, token) ==
               {:error, :transaction_aborted}

      assert Repo.get!(Usuario, usuario.id).email == usuario.email
      assert Repo.get_by(UsuarioToken, usuario_id: usuario.id)
    end
  end

  describe "change_usuario_password/3" do
    test "returns a usuario changeset" do
      assert %Ecto.Changeset{} = changeset = Autenticacion.change_usuario_password(%Usuario{})
      assert changeset.required == [:password]
    end

    test "allows fields to be set" do
      changeset =
        Autenticacion.change_usuario_password(
          %Usuario{},
          %{
            "password" => "new valid password"
          },
          hash_password: false
        )

      assert changeset.valid?
      assert get_change(changeset, :password) == "new valid password"
      assert is_nil(get_change(changeset, :hashed_password))
    end
  end

  describe "update_usuario_password/2" do
    setup do
      %{usuario: usuario_fixture()}
    end

    test "validates password", %{usuario: usuario} do
      {:error, changeset} =
        Autenticacion.update_usuario_password(usuario, %{
          password: "not valid",
          password_confirmation: "another"
        })

      assert %{
               password: ["should be at least 12 character(s)"],
               password_confirmation: ["does not match password"]
             } = errors_on(changeset)
    end

    test "validates maximum values for password for security", %{usuario: usuario} do
      too_long = String.duplicate("db", 100)

      {:error, changeset} =
        Autenticacion.update_usuario_password(usuario, %{password: too_long})

      assert "should be at most 72 character(s)" in errors_on(changeset).password
    end

    test "updates the password", %{usuario: usuario} do
      {:ok, {usuario, expired_tokens}} =
        Autenticacion.update_usuario_password(usuario, %{
          password: "new valid password"
        })

      assert expired_tokens == []
      assert is_nil(usuario.password)
      assert Autenticacion.get_usuario_by_email_and_password(usuario.email, "new valid password")
    end

    test "deletes all tokens for the given usuario", %{usuario: usuario} do
      _ = Autenticacion.generate_usuario_session_token(usuario)

      {:ok, {_, _}} =
        Autenticacion.update_usuario_password(usuario, %{
          password: "new valid password"
        })

      refute Repo.get_by(UsuarioToken, usuario_id: usuario.id)
    end
  end

  describe "generate_usuario_session_token/1" do
    setup do
      %{usuario: usuario_fixture()}
    end

    test "generates a token", %{usuario: usuario} do
      token = Autenticacion.generate_usuario_session_token(usuario)
      assert usuario_token = Repo.get_by(UsuarioToken, token: token)
      assert usuario_token.context == "session"
      assert usuario_token.authenticated_at != nil

      # Creating the same token for another usuario should fail
      assert_raise Ecto.ConstraintError, fn ->
        Repo.insert!(%UsuarioToken{
          token: usuario_token.token,
          usuario_id: usuario_fixture().id,
          context: "session"
        })
      end
    end

    test "duplicates the authenticated_at of given usuario in new token", %{usuario: usuario} do
      usuario = %{usuario | authenticated_at: DateTime.add(DateTime.utc_now(:second), -3600)}
      token = Autenticacion.generate_usuario_session_token(usuario)
      assert usuario_token = Repo.get_by(UsuarioToken, token: token)
      assert usuario_token.authenticated_at == usuario.authenticated_at
      assert DateTime.compare(usuario_token.inserted_at, usuario.authenticated_at) == :gt
    end
  end

  describe "get_usuario_by_session_token/1" do
    setup do
      usuario = usuario_fixture()
      token = Autenticacion.generate_usuario_session_token(usuario)
      %{usuario: usuario, token: token}
    end

    test "returns usuario by token", %{usuario: usuario, token: token} do
      assert {session_usuario, token_inserted_at} = Autenticacion.get_usuario_by_session_token(token)
      assert session_usuario.id == usuario.id
      assert session_usuario.authenticated_at != nil
      assert token_inserted_at != nil
    end

    test "does not return usuario for invalid token" do
      refute Autenticacion.get_usuario_by_session_token("oops")
    end

    test "does not return usuario for expired token", %{token: token} do
      dt = ~N[2020-01-01 00:00:00]
      {1, nil} = Repo.update_all(UsuarioToken, set: [inserted_at: dt, authenticated_at: dt])
      refute Autenticacion.get_usuario_by_session_token(token)
    end
  end

  describe "get_usuario_by_magic_link_token/1" do
    setup do
      usuario = usuario_fixture()
      {encoded_token, _hashed_token} = generate_usuario_magic_link_token(usuario)
      %{usuario: usuario, token: encoded_token}
    end

    test "returns usuario by token", %{usuario: usuario, token: token} do
      assert session_usuario = Autenticacion.get_usuario_by_magic_link_token(token)
      assert session_usuario.id == usuario.id
    end

    test "does not return usuario for invalid token" do
      refute Autenticacion.get_usuario_by_magic_link_token("oops")
    end

    test "does not return usuario for expired token", %{token: token} do
      {1, nil} = Repo.update_all(UsuarioToken, set: [inserted_at: ~N[2020-01-01 00:00:00]])
      refute Autenticacion.get_usuario_by_magic_link_token(token)
    end
  end

  describe "login_usuario_by_magic_link/1" do
    test "confirms usuario and expires tokens" do
      usuario = unconfirmed_usuario_fixture()
      refute usuario.confirmed_at
      {encoded_token, hashed_token} = generate_usuario_magic_link_token(usuario)

      assert {:ok, {usuario, [%{token: ^hashed_token}]}} =
               Autenticacion.login_usuario_by_magic_link(encoded_token)

      assert usuario.confirmed_at
    end

    test "returns usuario and (deleted) token for confirmed usuario" do
      usuario = usuario_fixture()
      assert usuario.confirmed_at
      {encoded_token, _hashed_token} = generate_usuario_magic_link_token(usuario)
      assert {:ok, {^usuario, []}} = Autenticacion.login_usuario_by_magic_link(encoded_token)
      # one time use only
      assert {:error, :not_found} = Autenticacion.login_usuario_by_magic_link(encoded_token)
    end

    test "raises when unconfirmed usuario has password set" do
      usuario = unconfirmed_usuario_fixture()
      {1, nil} = Repo.update_all(Usuario, set: [hashed_password: "hashed"])
      {encoded_token, _hashed_token} = generate_usuario_magic_link_token(usuario)

      assert_raise RuntimeError, ~r/magic link log in is not allowed/, fn ->
        Autenticacion.login_usuario_by_magic_link(encoded_token)
      end
    end
  end

  describe "delete_usuario_session_token/1" do
    test "deletes the token" do
      usuario = usuario_fixture()
      token = Autenticacion.generate_usuario_session_token(usuario)
      assert Autenticacion.delete_usuario_session_token(token) == :ok
      refute Autenticacion.get_usuario_by_session_token(token)
    end
  end

  describe "deliver_login_instructions/2" do
    setup do
      %{usuario: unconfirmed_usuario_fixture()}
    end

    test "sends token through notification", %{usuario: usuario} do
      token =
        extract_usuario_token(fn url ->
          Autenticacion.deliver_login_instructions(usuario, url)
        end)

      {:ok, token} = Base.url_decode64(token, padding: false)
      assert usuario_token = Repo.get_by(UsuarioToken, token: :crypto.hash(:sha256, token))
      assert usuario_token.usuario_id == usuario.id
      assert usuario_token.sent_to == usuario.email
      assert usuario_token.context == "login"
    end
  end

  describe "inspect/2 for the Usuario module" do
    test "does not include password" do
      refute inspect(%Usuario{password: "123456"}) =~ "password: \"123456\""
    end
  end
end
