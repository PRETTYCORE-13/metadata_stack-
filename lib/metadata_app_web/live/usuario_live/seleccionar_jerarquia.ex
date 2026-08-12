defmodule MetadataAppWeb.UsuarioLive.SeleccionarJerarquia do
  @moduledoc """
  Selección de jerarquía operativa activa (branch/inventory_location
  obligatorios, sales_unit opcional) — mismo criterio que
  UsuarioLive.SeleccionarEmpresa, pero acá pueden hacer falta 2 o 3
  elecciones a la vez, así que es un form real (no una lista de links)
  que postea a JerarquiaSessionController.activar/2 -- LiveView no puede
  escribir la sesión HTTP directo, necesita el roundtrip de un POST real
  (mismo motivo que EmpresaSessionController ya existe aparte).
  """
  use MetadataAppWeb, :live_view

  alias MetadataApp.Autenticacion

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-sm">
        <.header>Elegí con qué sucursal y almacén querés operar</.header>

        <form method="post" action={~p"/meta_schema_usuario/jerarquia/activar"} class="mt-6 space-y-4">
          <input type="hidden" name="_csrf_token" value={Phoenix.Controller.get_csrf_token()} />

          <.campo_jerarquia
            etiqueta="Sucursal"
            nombre="branch_id"
            estado={@branch_estado}
            campo_nombre={:branch_name}
          />

          <.campo_jerarquia
            etiqueta="Almacén"
            nombre="inventory_location_id"
            estado={@inventory_estado}
            campo_nombre={:inventory_name}
          />

          <.campo_jerarquia
            etiqueta="Unidad de venta (opcional)"
            nombre="sales_unit_id"
            estado={@sales_unit_estado}
            campo_nombre={:sales_unit_name}
            opcional?={true}
          />

          <button :if={@puede_continuar?} type="submit" class="btn btn-primary w-full">
            Continuar
          </button>
        </form>
      </div>
    </Layouts.app>
    """
  end

  attr :etiqueta, :string, required: true
  attr :nombre, :string, required: true
  attr :estado, :any, required: true
  attr :campo_nombre, :atom, required: true
  attr :opcional?, :boolean, default: false

  defp campo_jerarquia(%{estado: {:automatico, valor}} = assigns) do
    assigns = assign(assigns, :valor, valor)

    ~H"""
    <div>
      <p class="text-sm text-gray-500">{@etiqueta}</p>
      <p class="font-semibold">{Map.fetch!(@valor, @campo_nombre)}</p>
      <input type="hidden" name={@nombre} value={@valor.id} />
    </div>
    """
  end

  defp campo_jerarquia(%{estado: {:pendiente, opciones}} = assigns) do
    assigns = assign(assigns, :opciones, opciones)

    ~H"""
    <div>
      <label class="text-sm text-gray-500">{@etiqueta}</label>
      <select name={@nombre} class="select select-bordered w-full" required={!@opcional?}>
        <option :if={@opcional?} value="">Ninguna</option>
        <option :for={opcion <- @opciones} value={opcion.id}>{Map.fetch!(opcion, @campo_nombre)}</option>
      </select>
    </div>
    """
  end

  defp campo_jerarquia(%{estado: {:vacio}, opcional?: true} = assigns) do
    ~H""
  end

  defp campo_jerarquia(%{estado: {:vacio}} = assigns) do
    ~H"""
    <div>
      <p class="text-sm text-gray-500">{@etiqueta}</p>
      <p class="alert alert-outline">
        Todavía no tenés ninguna sucursal/almacén asignado. Contactá a un administrador.
      </p>
    </div>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    %{usuario: usuario, empresa_activa: empresa} = socket.assigns.current_scope
    es_administrador? = MetadataApp.Permissions.administrador?(usuario.id, empresa.id)
    jerarquia = Autenticacion.resolver_jerarquia_operativa(usuario.id, empresa.id, es_administrador?)

    puede_continuar? = not match?({:vacio}, jerarquia.branch) and not match?({:vacio}, jerarquia.inventory_location)

    {:ok,
     socket
     |> assign(:branch_estado, jerarquia.branch)
     |> assign(:inventory_estado, jerarquia.inventory_location)
     |> assign(:sales_unit_estado, jerarquia.sales_unit)
     |> assign(:puede_continuar?, puede_continuar?)}
  end
end
