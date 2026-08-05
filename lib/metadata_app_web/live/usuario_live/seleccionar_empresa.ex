defmodule MetadataAppWeb.UsuarioLive.SeleccionarEmpresa do
  use MetadataAppWeb, :live_view

  alias MetadataApp.Autenticacion

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-sm">
        <.header>Elegí con qué empresa querés trabajar</.header>

        <ul :if={@empresas != []} class="mt-6 space-y-2">
          <li :for={empresa <- @empresas}>
            <.link
              href={~p"/meta_schema_usuario/empresa/#{empresa.id}/activar"}
              method="post"
              class="btn btn-primary w-full"
            >
              {empresa.nombre}
            </.link>
          </li>
        </ul>

        <p :if={@empresas == []} class="alert alert-outline mt-6">
          Todavía no tienes ninguna empresa asignada. Contacta a un administrador.
        </p>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    empresas = Autenticacion.empresas_de_usuario(socket.assigns.current_scope.usuario.id)
    {:ok, assign(socket, empresas: empresas)}
  end
end
