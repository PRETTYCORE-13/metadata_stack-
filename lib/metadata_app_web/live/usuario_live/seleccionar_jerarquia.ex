defmodule MetadataAppWeb.UsuarioLive.SeleccionarJerarquia do
  @moduledoc """
  Selección de jerarquía operativa activa (branch/inventory_location
  obligatorios, sales_unit opcional) — mismo criterio que
  UsuarioLive.SeleccionarEmpresa, pero acá pueden hacer falta 2 o 3
  elecciones a la vez, así que es un form real (no una lista de links)
  que postea a JerarquiaSessionController.activar/2 -- LiveView no puede
  escribir la sesión HTTP directo, necesita el roundtrip de un POST real
  (mismo motivo que EmpresaSessionController ya existe aparte).

  Arquitectura ERP (2026-08-13): Empresa -> N Branch -> N Inventory -> N
  Sales Unit -- un almacén pertenece a UNA sucursal, así que si la
  sucursal está "pendiente" (2+ permitidas, sin default), Almacén/Unidad
  de venta NO se pueden resolver hasta saber CUÁL sucursal eligió el
  usuario. El <select> de Sucursal es phx-change (recalcula las opciones
  de Almacén/Unidad de venta en vivo, sin recargar la página) aunque el
  form entero siga siendo un POST plano -- LiveView solo actualiza qué
  <option>s se ofrecen, el submit final lo sigue manejando el controller.
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
            phx_change="elegir_branch_pendiente"
          />

          <.campo_jerarquia
            etiqueta="Almacén"
            nombre="inventory_location_id"
            estado={@inventory_estado}
            campo_nombre={:inventory_name}
            branch_estado={@branch_estado}
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
  attr :phx_change, :string, default: nil
  attr :branch_estado, :any, default: nil

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
      <select name={@nombre} phx-change={@phx_change} class="select select-bordered w-full" required={!@opcional?}>
        <option :if={@opcional?} value="">Ninguna</option>
        <option value="" disabled selected>Elegí una opción...</option>
        <option :for={opcion <- @opciones} value={opcion.id}>{Map.fetch!(opcion, @campo_nombre)}</option>
      </select>
    </div>
    """
  end

  defp campo_jerarquia(%{estado: {:vacio}, opcional?: true} = assigns) do
    ~H""
  end

  # Sucursal en {:vacio} = de verdad no tiene ninguna asignada. Almacén
  # en {:vacio} puede ser por lo mismo, O porque la sucursal todavía está
  # {:pendiente} de elegir arriba -- mensaje distinto para no confundir
  # "no tenés nada" con "elegí la sucursal primero".
  defp campo_jerarquia(%{estado: {:vacio}, nombre: "inventory_location_id", branch_estado: {:pendiente, _}} = assigns) do
    ~H"""
    <div>
      <p class="text-sm text-gray-500">{@etiqueta}</p>
      <p class="alert alert-outline">Elegí primero una sucursal.</p>
    </div>
    """
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

    {:ok,
     socket
     |> assign(:usuario_id, usuario.id)
     |> assign(:empresa_id, empresa.id)
     |> assign(:es_administrador?, es_administrador?)
     |> assign(:branch_estado, jerarquia.branch)
     |> assign(:inventory_estado, jerarquia.inventory_location)
     |> assign(:sales_unit_estado, jerarquia.sales_unit)
     |> assign(:puede_continuar?, puede_continuar?(jerarquia))}
  end

  defp puede_continuar?(jerarquia), do: not match?({:vacio}, jerarquia.branch) and not match?({:vacio}, jerarquia.inventory_location)

  # Disparado al elegir una sucursal del <select> "pendiente" -- re-resuelve
  # Almacén/Unidad de venta EN VIVO para esa sucursal puntual (antes de
  # esto, ni siquiera existía el concepto de "elegí primero la sucursal",
  # todo se resolvía junto e independiente). branch_estado NO cambia acá
  # a propósito (sigue {:pendiente, opciones}, es el <select> el que ya
  # tiene la elección) -- si al final el usuario cambia de sucursal otra
  # vez, este mismo evento recalcula de nuevo.
  @impl true
  def handle_event("elegir_branch_pendiente", %{"branch_id" => branch_id}, socket) do
    %{usuario_id: usuario_id, empresa_id: empresa_id, es_administrador?: es_administrador?} = socket.assigns

    case Integer.parse(branch_id) do
      {branch_id, ""} ->
        jerarquia = Autenticacion.resolver_inventario_de_branch(usuario_id, empresa_id, branch_id, es_administrador?)

        {:noreply,
         socket
         |> assign(:inventory_estado, jerarquia.inventory_location)
         |> assign(:sales_unit_estado, jerarquia.sales_unit)
         |> assign(
           :puede_continuar?,
           not match?({:vacio}, socket.assigns.branch_estado) and not match?({:vacio}, jerarquia.inventory_location)
         )}

      :error ->
        {:noreply, socket}
    end
  end

  def handle_event("elegir_branch_pendiente", _params, socket), do: {:noreply, socket}
end
