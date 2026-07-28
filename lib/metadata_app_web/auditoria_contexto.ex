defmodule MetadataAppWeb.AuditoriaContexto do
  @moduledoc """
  Arma el `contexto` que espera `CatalogoGenerico.crear/actualizar/eliminar`
  (roadmap #6 — Fase 2) a partir de un `conn` (API) o un `socket` de
  LiveView — un solo lugar para no repetir 3 veces cómo se saca
  usuario/empresa/ip/user-agent.

  IP: `conn.remote_ip`/`peer_data.address` tal cual, SIN mirar
  `x-forwarded-for` — no hay ningún reverse proxy delante de la app hoy
  (deploy directo a Docker Swarm, ver `docs/ci-cd-deploy.md`), y confiar en
  ese header sin un proxy real que lo sanee es un hueco de spoofing (calquier
  cliente puede mandar el header que quiera). Si el día de mañana se agrega
  un proxy/ingress delante, esto necesita revisarse (`RemoteIp` u
  equivalente, confiando SOLO en el proxy conocido).
  """

  alias MetadataApp.Autenticacion.Scope

  def desde_conn(%Plug.Conn{} = conn) do
    %{
      usuario_id: usuario_id(conn.assigns[:current_scope]),
      usuario_email: usuario_email(conn.assigns[:current_scope]),
      empresa_id: empresa_id(conn.assigns[:current_scope]),
      ip: ip_a_texto(conn.remote_ip),
      user_agent: conn |> Plug.Conn.get_req_header("user-agent") |> List.first()
    }
  end

  def desde_socket(socket) do
    peer_data = Phoenix.LiveView.get_connect_info(socket, :peer_data)
    scope = socket.assigns[:current_scope]

    %{
      usuario_id: usuario_id(scope),
      usuario_email: usuario_email(scope),
      empresa_id: empresa_id(scope),
      ip: ip_a_texto(peer_data && peer_data.address),
      user_agent: Phoenix.LiveView.get_connect_info(socket, :user_agent)
    }
  end

  defp usuario_id(%Scope{usuario: usuario}) when not is_nil(usuario), do: usuario.id
  defp usuario_id(_sin_scope), do: nil

  defp usuario_email(%Scope{usuario: usuario}) when not is_nil(usuario), do: usuario.email
  defp usuario_email(_sin_scope), do: nil

  defp empresa_id(%Scope{empresa_activa: empresa}) when not is_nil(empresa), do: empresa.id
  defp empresa_id(_sin_scope), do: nil

  defp ip_a_texto(nil), do: nil
  defp ip_a_texto(tupla), do: tupla |> :inet.ntoa() |> to_string()
end
