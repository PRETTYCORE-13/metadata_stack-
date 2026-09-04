defmodule MetadataApp.Autenticacion.SesionMovil do
  @moduledoc """
  Sesión de la app Flutter (SPEC-API-0409202601, design.md §2) -- el
  refresh token de un login móvil. Mismo patrón que `UsuarioToken`
  (módulo puro: arma structs/queries, nunca llama a `Repo` -- eso vive
  en `MetadataApp.Autenticacion`) pero en tabla aparte, porque esta
  necesita campos que `UsuarioToken` no tiene (`etiqueta_dispositivo`,
  `ultimo_uso_en`) y se actualiza en cada refresh en vez de ser de un
  solo uso.
  """
  use Ecto.Schema
  import Ecto.Query
  alias MetadataApp.Autenticacion.SesionMovil

  @hash_algorithm :sha256
  @rand_size 32

  # design.md §1: 60 días -- refresh token de mobile, no confundir con
  # UsuarioToken.@session_validity_in_hours (12hs, sesión web por cookie).
  @refresh_validity_in_days 60

  schema "meta_schema_usuario_sesion_movil" do
    field :refresh_token_hash, :binary
    field :etiqueta_dispositivo, :string
    field :ultimo_uso_en, :utc_datetime
    belongs_to :usuario, MetadataApp.Autenticacion.Usuario

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc """
  Arma una sesión nueva -- devuelve `{token_crudo, %SesionMovil{}}`.
  El crudo se manda al cliente (nunca se guarda); el hash es lo que
  persiste en `refresh_token_hash` (mismo criterio que
  `UsuarioToken.build_hashed_token/3` para magic-link/cambio de email).
  """
  def build(usuario, etiqueta_dispositivo) do
    token = :crypto.strong_rand_bytes(@rand_size)
    hashed_token = :crypto.hash(@hash_algorithm, token)

    {Base.url_encode64(token, padding: false),
     %SesionMovil{
       refresh_token_hash: hashed_token,
       etiqueta_dispositivo: etiqueta_dispositivo,
       usuario_id: usuario.id
     }}
  end

  @doc """
  Query que matchea la sesión de un refresh token crudo, SIN filtrar
  por vigencia -- para casos que necesitan encontrarla igual aunque ya
  haya vencido (ej. revocar/logout explícito, ver
  `Autenticacion.revocar_sesion_movil_por_token/1`). Devuelve
  `{:ok, query}` o `:error` si el token ni siquiera decodifica.
  """
  def buscar_por_token_query(token_crudo) do
    case Base.url_decode64(token_crudo, padding: false) do
      {:ok, decoded_token} ->
        hashed_token = :crypto.hash(@hash_algorithm, decoded_token)
        {:ok, from(sesion in SesionMovil, where: sesion.refresh_token_hash == ^hashed_token)}

      :error ->
        :error
    end
  end

  @doc """
  Query para VALIDAR un refresh token crudo -- válido si el hash
  coincide y además no pasaron más de #{@refresh_validity_in_days}
  días desde que se creó (mismo patrón que
  `UsuarioToken.verify_session_token_query/1`, ventana distinta).
  """
  def verify_refresh_token_query(token_crudo) do
    with {:ok, query} <- buscar_por_token_query(token_crudo) do
      {:ok, from(sesion in query, where: sesion.inserted_at > ago(@refresh_validity_in_days, "day"))}
    end
  end
end
