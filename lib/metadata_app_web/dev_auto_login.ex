defmodule MetadataAppWeb.DevAutoLogin do
  @moduledoc """
  Auto-login transparente SOLO para desarrollo local — evita tener que
  pasar por el flujo de magic-link cada vez que alguien levanta
  `mix phx.server` en su laptop.

  Gateado a COMPILE-TIME (`Application.compile_env/3`, mismo criterio que
  `bpb_habilitado`/`dev_routes`, ver `config/dev.exs`): en un release
  compilado con `MIX_ENV=prod` (o `:test`) esto queda baked-in en `false`
  — no hay ninguna variable de entorno en runtime que pueda prenderlo por
  accidente en producción.

  Busca (o crea, la primera vez) un usuario demo fijo — confirmado, con
  su propia empresa y rol "administrador" (reusa
  `Autenticacion.crear_empresa_para_usuario/2`, la misma función que ya
  usa el registro real) — y le arma la sesión ANTES de
  `fetch_current_scope_for_usuario/2`, así el resto del pipeline lo ve
  exactamente como si hubiera hecho login real. Si YA hay una sesión
  (alguien hizo login de verdad, o inició sesión como otro usuario para
  probar permisos), no toca nada.
  """

  import Plug.Conn
  alias MetadataApp.Autenticacion
  alias MetadataApp.Autenticacion.{Empresa, Usuario}
  alias MetadataApp.Repo

  @correo "demo@mail.com"
  @empresa_nombre "Demo Local"
  @habilitado Application.compile_env(:metadata_app, :auto_login_demo_dev, false)

  def init(opts), do: opts

  def call(conn, _opts) do
    if @habilitado and is_nil(get_session(conn, :usuario_token)) do
      auto_login(conn)
    else
      conn
    end
  end

  defp auto_login(conn) do
    usuario = obtener_o_crear_usuario_demo()
    token = Autenticacion.generate_usuario_session_token(usuario)
    empresa_id = empresa_activa_de(usuario)

    conn
    |> put_session(:usuario_token, token)
    |> then(fn conn -> if empresa_id, do: put_session(conn, :empresa_activa_id, empresa_id), else: conn end)
  end

  defp obtener_o_crear_usuario_demo do
    case Autenticacion.get_usuario_by_email(@correo) do
      nil ->
        {:ok, usuario} = Autenticacion.register_usuario(%{"email" => @correo})
        confirmar(usuario)

      %Usuario{confirmed_at: nil} = usuario ->
        confirmar(usuario)

      usuario ->
        usuario
    end
  end

  defp confirmar(usuario) do
    {:ok, usuario} = usuario |> Usuario.confirm_changeset() |> Repo.update()
    usuario
  end

  defp empresa_activa_de(usuario) do
    case Autenticacion.empresas_de_usuario(usuario.id) do
      [%Empresa{id: id} | _] ->
        id

      [] ->
        case Autenticacion.crear_empresa_para_usuario(@empresa_nombre, usuario.id) do
          {:ok, empresa} -> empresa.id
          _ -> nil
        end
    end
  end
end
