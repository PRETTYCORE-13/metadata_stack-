defmodule MetadataApp.Autenticacion.UsuarioNotifier do
  import Swoosh.Email

  alias MetadataApp.Mailer
  alias MetadataApp.Autenticacion.Usuario

  # Delivers the email using the application mailer.
  defp deliver(recipient, subject, body) do
    remitente = Application.get_env(:metadata_app, :mailer_from, "contact@example.com")

    email =
      new()
      |> to(recipient)
      |> from({"MetadataApp", remitente})
      |> subject(subject)
      |> text_body(body)

    with {:ok, _metadata} <- Mailer.deliver(email) do
      {:ok, email}
    end
  end

  @doc """
  Deliver instructions to update a usuario email.
  """
  def deliver_update_email_instructions(usuario, url) do
    deliver(usuario.email, "Update email instructions", """

    ==============================

    Hi #{usuario.email},

    You can change your email by visiting the URL below:

    #{url}

    If you didn't request this change, please ignore this.

    ==============================
    """)
  end

  @doc """
  Deliver instructions to log in with a magic link.
  """
  def deliver_login_instructions(usuario, url) do
    case usuario do
      %Usuario{confirmed_at: nil} -> deliver_confirmation_instructions(usuario, url)
      _ -> deliver_magic_link_instructions(usuario, url)
    end
  end

  defp deliver_magic_link_instructions(usuario, url) do
    deliver(usuario.email, "Log in instructions", """

    ==============================

    Hi #{usuario.email},

    You can log into your account by visiting the URL below:

    #{url}

    If you didn't request this email, please ignore this.

    ==============================
    """)
  end

  defp deliver_confirmation_instructions(usuario, url) do
    deliver(usuario.email, "Confirmation instructions", """

    ==============================

    Hi #{usuario.email},

    You can confirm your account by visiting the URL below:

    #{url}

    If you didn't create an account with us, please ignore this.

    ==============================
    """)
  end
end
