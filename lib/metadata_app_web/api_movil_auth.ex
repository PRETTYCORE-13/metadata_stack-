defmodule MetadataAppWeb.ApiMovilAuth do
  @moduledoc """
  Plug de autenticación para `/api/movil` (SPEC-API-0409202601,
  design.md §1.3) -- lee `Authorization: Bearer <access_token>`,
  verifica firma+expiración+revocación (`Autenticacion.
  verificar_access_token/1`) y arma `current_scope` igual que el resto
  del sistema (mismo struct `Scope` que usa la sesión web, para que
  cualquier endpoint futuro que ya sepa trabajar con `current_scope`
  funcione sin cambios). La empresa activa se resuelve FRESCA en cada
  request (`Autenticacion.empresa_resuelta_para_login_movil/1`), no se
  guarda en el token -- mismo criterio de revalidación que ya usa
  `MetadataAppWeb.UsuarioAuth.hidratar_empresa_activa/2` para la web (si
  le revocaron el acceso a esa empresa después del login, no se arrastra
  una referencia inválida).
  """

  import Plug.Conn
  alias MetadataApp.Autenticacion
  alias MetadataApp.Autenticacion.Scope

  def init(opts), do: opts

  def call(conn, _opts) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         {:ok, usuario} <- Autenticacion.verificar_access_token(token) do
      scope =
        Scope.for_usuario(usuario)
        |> Scope.con_empresa_activa(Autenticacion.empresa_resuelta_para_login_movil(usuario.id))

      assign(conn, :current_scope, scope)
    else
      _ -> rechazar(conn)
    end
  end

  defp rechazar(conn) do
    conn
    |> put_status(:unauthorized)
    |> Phoenix.Controller.json(%{error: "no_autenticado"})
    |> halt()
  end
end
