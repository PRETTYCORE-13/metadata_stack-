defmodule MetadataAppWeb.RequierePrimerArranque do
  @moduledoc """
  Mientras no exista NINGÚN sysadmin, redirige cualquier request al
  wizard de primer arranque (docs/onboarding-nuevo-sistema.md, Fase 2)
  en vez de dejar pasar la navegación normal -- un sistema recién
  migrado de cero, sin sysadmin, quedaría en un loop irrecuperable
  contra "seleccionar-empresa" sin esto (encontrado en vivo, 2026-08-14,
  bootstrap de 167.233.84.151 -- la única salida fue un RPC manual).

  `:persistent_term` en vez de consultar la base en cada request: una
  vez que existe un sysadmin, NUNCA vuelve a dejar de existir (no hay
  "borrar sysadmin" en la app) -- cachear el resultado positivo para
  siempre es seguro y evita una query de más en TODO request de TODO
  sistema, para siempre, solo para confirmar algo que después del
  primer arranque nunca cambia.
  """

  import Plug.Conn
  import Phoenix.Controller, only: [redirect: 2]

  alias MetadataApp.Autenticacion

  @ruta_wizard "/primer-arranque"
  @prefijos_exentos ["/assets", "/dev", "/api"]
  @habilitado Application.compile_env(:metadata_app, :requiere_primer_arranque_habilitado, true)

  def init(opts), do: opts

  def call(conn, _opts) do
    if not @habilitado or conn.request_path == @ruta_wizard or exento?(conn) or sysadmin_existe?() do
      conn
    else
      conn |> redirect(to: @ruta_wizard) |> halt()
    end
  end

  defp exento?(conn) do
    Enum.any?(@prefijos_exentos, &String.starts_with?(conn.request_path, &1))
  end

  defp sysadmin_existe? do
    case :persistent_term.get({__MODULE__, :sysadmin_existe}, false) do
      true ->
        true

      false ->
        if Autenticacion.existe_sysadmin?() do
          :persistent_term.put({__MODULE__, :sysadmin_existe}, true)
          true
        else
          false
        end
    end
  end
end
