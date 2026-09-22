defmodule MetadataAppWeb.Plugs.RequierePermiso do
  @moduledoc """
  Plug REST de autorización — `plug MetadataAppWeb.Plugs.RequierePermiso,
  accion: "leer"` (recurso fijo opcional vía `recurso:`; si no se pasa, se
  toma de `conn.params["tabla"]`, para las rutas genéricas `/api/:tabla`).

  SPEC-SYS-2209202601 (design.md §2) -- `accion` también es dinámica: si
  no se pasa fija, se toma de `conn.params["accion"]` (rutas de
  transición, `/api/:tabla/:id/transiciones/:accion` -- el permiso a
  chequear es el nombre de la transición pedida, no un string fijo).
  Mismo criterio simétrico que ya existía para `recurso`/`"tabla"`.

  Requiere que el pipeline ya haya corrido `fetch_current_scope_for_usuario`
  (ver pipeline `:api`). Shape de error igual al resto de la API
  (`MetadataAppWeb.FallbackController`): `%{errors: %{detail: ...}}`, nunca
  un shape nuevo.
  """

  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  alias MetadataApp.Permissions
  alias MetadataApp.Autenticacion.Scope

  def init(opts), do: opts

  def call(conn, opts) do
    recurso = Keyword.get(opts, :recurso) || conn.params["tabla"]

    accion =
      Keyword.get(opts, :accion) || conn.params["accion"] ||
        raise "RequierePermiso: falta :accion (ni fijo en el plug ni conn.params[\"accion\"])"

    case conn.assigns[:current_scope] do
      %Scope{usuario: usuario} = scope when not is_nil(usuario) ->
        if Permissions.can?(scope, accion, recurso) do
          conn
        else
          conn
          |> put_status(:forbidden)
          |> json(%{errors: %{detail: "sin permiso"}})
          |> halt()
        end

      _ ->
        conn
        |> put_status(:unauthorized)
        |> json(%{errors: %{detail: "no autenticado"}})
        |> halt()
    end
  end
end
