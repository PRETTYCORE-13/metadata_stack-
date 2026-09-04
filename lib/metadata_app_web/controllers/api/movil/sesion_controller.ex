defmodule MetadataAppWeb.Api.Movil.SesionController do
  @moduledoc """
  Autenticación de la app Flutter (SPEC-API-0409202601, design.md §4)
  -- verificar instancia+usuario (R11), login (R1/R2), renovar access
  token (R3/R4), logout (R8). Sin `action_fallback`: cada acción
  maneja sus propios códigos de error a propósito (el contrato de §4
  es específico por acción, no un formato de error genérico).
  """
  use MetadataAppWeb, :controller

  alias MetadataApp.Autenticacion
  alias MetadataApp.Autenticacion.LimiteIntentos

  @doc "R11 -- confirma instancia+usuario antes de pedir contraseña, sin loguear a nadie."
  def verificar(conn, %{"email" => email}) do
    if LimiteIntentos.bloqueado?(email) do
      responder_bloqueado(conn, email)
    else
      case Autenticacion.get_usuario_by_email(email) do
        nil ->
          LimiteIntentos.registrar_intento_fallido(email)
          conn |> put_status(:not_found) |> json(%{existe: false, error: "usuario_no_encontrado"})

        usuario ->
          empresa = Autenticacion.empresa_resuelta_para_login_movil(usuario.id)
          json(conn, %{existe: true, empresa: serializar_empresa(empresa)})
      end
    end
  end

  @doc "R1/R2 -- login real, emite access+refresh token."
  def create(conn, %{"email" => email, "password" => password} = params) do
    if LimiteIntentos.bloqueado?(email) do
      responder_bloqueado(conn, email)
    else
      case Autenticacion.get_usuario_by_email_and_password(email, password) do
        nil ->
          LimiteIntentos.registrar_intento_fallido(email)
          conn |> put_status(:unauthorized) |> json(%{error: "credenciales_invalidas"})

        usuario ->
          LimiteIntentos.limpiar(email)
          etiqueta = Map.get(params, "etiqueta_dispositivo")
          {refresh_token, sesion} = Autenticacion.crear_sesion_movil(usuario, etiqueta)
          access_token = Autenticacion.emitir_access_token(sesion)
          empresa = Autenticacion.empresa_resuelta_para_login_movil(usuario.id)

          json(conn, %{
            access_token: access_token,
            refresh_token: refresh_token,
            access_token_expira_en: Autenticacion.access_token_max_age_seconds(),
            usuario: %{id: usuario.id, email: usuario.email, alias: usuario.alias},
            empresa: serializar_empresa(empresa)
          })
      end
    end
  end

  @doc "R3/R4 -- renueva el access token a partir de un refresh token válido."
  def refrescar(conn, %{"refresh_token" => refresh_token}) do
    case Autenticacion.obtener_sesion_movil_valida(refresh_token) do
      {:ok, sesion} ->
        sesion = Autenticacion.tocar_sesion_movil(sesion)
        access_token = Autenticacion.emitir_access_token(sesion)
        json(conn, %{access_token: access_token, access_token_expira_en: Autenticacion.access_token_max_age_seconds()})

      :error ->
        conn |> put_status(:unauthorized) |> json(%{error: "refresh_token_invalido"})
    end
  end

  @doc "R8 -- logout explícito, idempotente."
  def delete(conn, %{"refresh_token" => refresh_token}) do
    :ok = Autenticacion.revocar_sesion_movil_por_token(refresh_token)
    send_resp(conn, :no_content, "")
  end

  defp responder_bloqueado(conn, email) do
    conn
    |> put_status(:too_many_requests)
    |> json(%{error: "demasiados_intentos", reintentar_en_segundos: LimiteIntentos.reintentar_en_segundos(email)})
  end

  defp serializar_empresa(nil), do: nil
  defp serializar_empresa(empresa), do: %{id: empresa.id, nombre: empresa.nombre}
end
