defmodule MetadataAppWeb.Hooks.Autorizacion do
  @moduledoc """
  `on_mount` genérico de autorización — `on_mount {__MODULE__, {recurso, accion}}`.

  Tiene que declararse DESPUÉS de `{MetadataAppWeb.UsuarioAuth,
  :mount_current_scope}` (o `:require_authenticated`) en la misma LiveView,
  para que `@current_scope` ya esté armado cuando esto corre.

  No autenticado -> a login. Autenticado pero sin el permiso -> a home con
  flash (nunca revela más que "no tenés permiso").
  """

  import Phoenix.LiveView
  use MetadataAppWeb, :verified_routes

  alias MetadataApp.Permissions
  alias MetadataApp.Autenticacion.Scope

  def on_mount({recurso, accion}, _params, _session, socket) do
    case socket.assigns[:current_scope] do
      %Scope{usuario: usuario} = scope when not is_nil(usuario) ->
        if Permissions.can?(scope, accion, recurso) do
          {:cont, socket}
        else
          {:halt,
           socket
           |> put_flash(:error, "No tenés permiso para acceder a esto.")
           |> redirect(to: ~p"/")}
        end

      _ ->
        {:halt,
         socket
         |> put_flash(:error, "Tenés que iniciar sesión para acceder a esto.")
         |> redirect(to: ~p"/meta_schema_usuario/log-in")}
    end
  end
end
