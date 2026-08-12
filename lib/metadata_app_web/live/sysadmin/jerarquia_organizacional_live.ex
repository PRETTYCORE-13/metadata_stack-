defmodule MetadataAppWeb.Sysadmin.JerarquiaOrganizacionalLive do
  @moduledoc """
  Administrador de la jerarquía organizacional (Fase 0 del modelo de
  Alcance de Datos, 2026-08-11) — Empresa -> Branch -> {SalesUnit,
  InventoryLocation}. Empresa se administra en EmpresasLive de siempre;
  acá solo lo nuevo: sucursales de una empresa, y las Sales Units /
  Inventory Locations de una sucursal seleccionada, lado a lado.
  """

  use MetadataAppWeb, :live_view_admin

  on_mount {MetadataAppWeb.UsuarioAuth, :mount_current_scope}
  on_mount {MetadataAppWeb.Hooks.Autorizacion, {"rbac_admin", "leer"}}

  alias MetadataApp.Autenticacion
  alias MetadataApp.Autenticacion.{Branch, SalesUnit, InventoryLocation}
  alias MetadataAppWeb.AdminNav

  @menu [
    %{tipo: :pagina, id: "bc_list", label: "BC List", nav: "/sysadmin/bc-list"},
    %{tipo: :pagina, id: "buscar_trn", label: "Buscar TRN", nav: "/sysadmin/buscar-trn"},
    %{tipo: :pagina, id: "tepache", label: "Tepache Exp/Imp", nav: "/sysadmin/tepache"},
    %{tipo: :pagina, id: "roles", label: "Roles y Usuarios", nav: "/sysadmin/roles"},
    %{tipo: :pagina, id: "usuarios_empresa", label: "Usuarios", nav: "/sysadmin/usuarios"},
    %{tipo: :pagina, id: "empresas", label: "Empresas", nav: "/sysadmin/empresas"},
    %{tipo: :pagina, id: "credenciales", label: "Credenciales", nav: "/sysadmin/credenciales"},
    %{tipo: :pagina, id: "acciones_externas", label: "Acciones externas", nav: "/sysadmin/acciones-externas"},
    %{tipo: :pagina, id: "jerarquia", label: "Jerarquía organizacional", nav: "/sysadmin/jerarquia"}
  ]

  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:current_page, "jerarquia")
     |> assign(:menu_items, AdminNav.filtrar_menu(@menu))
     |> assign(:sidebar_open, false)
     |> assign(:show_programacion_children, false)
     |> assign(:show_clientes_children, false)
     |> assign(:show_prettycore_children, false)
     |> assign(:empresas, Autenticacion.listar_empresas())
     |> assign(:empresa_seleccionada, nil)
     |> assign(:branches, [])
     |> assign(:branch_form, nil)
     |> assign(:branch_seleccionada, nil)
     |> assign(:sales_units, [])
     |> assign(:sales_unit_form, nil)
     |> assign(:inventory_locations, [])
     |> assign(:inventory_location_form, nil)}
  end

  def handle_event("change_page", %{"id" => id}, socket) do
    AdminNav.handle_nav(id, socket, "jerarquia")
  end

  def handle_event("seleccionar_empresa", %{"id" => id}, socket) do
    empresa = Enum.find(socket.assigns.empresas, &(&1.id == String.to_integer(id)))

    {:noreply,
     socket
     |> assign(:empresa_seleccionada, empresa)
     |> assign(:branches, Autenticacion.listar_branches(empresa.id))
     |> assign(:branch_form, nil)
     |> cerrar_branch_seleccionada()}
  end

  def handle_event("nueva_branch", _params, socket) do
    {:noreply, assign(socket, :branch_form, to_form(Branch.changeset(%Branch{}, %{})))}
  end

  def handle_event("cerrar_branch_form", _params, socket) do
    {:noreply, assign(socket, :branch_form, nil)}
  end

  def handle_event("guardar_branch", %{"branch" => params}, socket) do
    params = Map.put(params, "empresa_id", socket.assigns.empresa_seleccionada.id)

    case Autenticacion.crear_branch(params) do
      {:ok, _branch} ->
        {:noreply,
         socket
         |> put_flash(:info, "Sucursal creada.")
         |> assign(:branch_form, nil)
         |> assign(:branches, Autenticacion.listar_branches(socket.assigns.empresa_seleccionada.id))}

      {:error, changeset} ->
        {:noreply, assign(socket, :branch_form, to_form(changeset, action: :validate))}
    end
  end

  def handle_event("seleccionar_branch", %{"id" => id}, socket) do
    branch = Enum.find(socket.assigns.branches, &(&1.id == String.to_integer(id)))

    {:noreply,
     socket
     |> assign(:branch_seleccionada, branch)
     |> assign(:sales_units, Autenticacion.listar_sales_units(branch.id))
     |> assign(:inventory_locations, Autenticacion.listar_inventory_locations(branch.id))
     |> assign(:sales_unit_form, nil)
     |> assign(:inventory_location_form, nil)}
  end

  def handle_event("nueva_sales_unit", _params, socket) do
    {:noreply, assign(socket, :sales_unit_form, to_form(SalesUnit.changeset(%SalesUnit{}, %{})))}
  end

  def handle_event("cerrar_sales_unit_form", _params, socket) do
    {:noreply, assign(socket, :sales_unit_form, nil)}
  end

  def handle_event("guardar_sales_unit", %{"sales_unit" => params}, socket) do
    params =
      params
      |> Map.put("empresa_id", socket.assigns.empresa_seleccionada.id)
      |> Map.put("branch_id", socket.assigns.branch_seleccionada.id)

    case Autenticacion.crear_sales_unit(params) do
      {:ok, _sales_unit} ->
        {:noreply,
         socket
         |> put_flash(:info, "Unidad de ventas creada.")
         |> assign(:sales_unit_form, nil)
         |> assign(:sales_units, Autenticacion.listar_sales_units(socket.assigns.branch_seleccionada.id))}

      {:error, changeset} ->
        {:noreply, assign(socket, :sales_unit_form, to_form(changeset, action: :validate))}
    end
  end

  def handle_event("eliminar_sales_unit", %{"id" => id}, socket) do
    sales_unit = Enum.find(socket.assigns.sales_units, &(&1.id == String.to_integer(id)))
    {:ok, _} = Autenticacion.eliminar_sales_unit(sales_unit)

    {:noreply,
     socket
     |> put_flash(:info, "Unidad de ventas eliminada.")
     |> assign(:sales_units, Autenticacion.listar_sales_units(socket.assigns.branch_seleccionada.id))}
  end

  def handle_event("nueva_inventory_location", _params, socket) do
    {:noreply, assign(socket, :inventory_location_form, to_form(InventoryLocation.changeset(%InventoryLocation{}, %{})))}
  end

  def handle_event("cerrar_inventory_location_form", _params, socket) do
    {:noreply, assign(socket, :inventory_location_form, nil)}
  end

  def handle_event("guardar_inventory_location", %{"inventory_location" => params}, socket) do
    params =
      params
      |> Map.put("empresa_id", socket.assigns.empresa_seleccionada.id)
      |> Map.put("branch_id", socket.assigns.branch_seleccionada.id)

    case Autenticacion.crear_inventory_location(params) do
      {:ok, _inventory_location} ->
        {:noreply,
         socket
         |> put_flash(:info, "Ubicación de inventario creada.")
         |> assign(:inventory_location_form, nil)
         |> assign(:inventory_locations, Autenticacion.listar_inventory_locations(socket.assigns.branch_seleccionada.id))}

      {:error, changeset} ->
        {:noreply, assign(socket, :inventory_location_form, to_form(changeset, action: :validate))}
    end
  end

  def handle_event("eliminar_inventory_location", %{"id" => id}, socket) do
    inventory_location = Enum.find(socket.assigns.inventory_locations, &(&1.id == String.to_integer(id)))
    {:ok, _} = Autenticacion.eliminar_inventory_location(inventory_location)

    {:noreply,
     socket
     |> put_flash(:info, "Ubicación de inventario eliminada.")
     |> assign(:inventory_locations, Autenticacion.listar_inventory_locations(socket.assigns.branch_seleccionada.id))}
  end

  defp cerrar_branch_seleccionada(socket) do
    socket
    |> assign(:branch_seleccionada, nil)
    |> assign(:sales_units, [])
    |> assign(:inventory_locations, [])
    |> assign(:sales_unit_form, nil)
    |> assign(:inventory_location_form, nil)
  end

  def render(assigns) do
    ~H"""
    <div class="p-6">
      <div class="flex items-center gap-2 mb-4">
        <.link navigate={~p"/"} title="Volver al inicio"
          class="w-7 h-7 flex items-center justify-center rounded-lg text-gray-500 hover:bg-gray-100 hover:text-gray-700 transition-colors shrink-0">
          <span class="material-symbols-outlined" style="font-size: 18px">arrow_back</span>
        </.link>
        <div>
          <h1 class="text-2xl font-bold">Jerarquía organizacional</h1>
          <p class="text-xs text-gray-400">Empresa → Sucursal → Unidades de venta / Ubicaciones de inventario.</p>
        </div>
      </div>

      <div class="flex gap-4 items-start">
        <div class="w-64 flex-shrink-0 border border-gray-200 rounded-xl overflow-hidden" style="height: 75vh">
          <div class="px-3 py-2 border-b border-gray-100 text-xs font-bold text-gray-500 uppercase">Empresas</div>
          <div class="overflow-y-auto" style="height: calc(75vh - 36px)">
            <button
              :for={empresa <- @empresas}
              type="button"
              phx-click="seleccionar_empresa"
              phx-value-id={empresa.id}
              class={[
                "w-full text-left px-3 py-2 text-sm border-b border-gray-50",
                @empresa_seleccionada && @empresa_seleccionada.id == empresa.id && "bg-purple-50 text-purple-700 font-semibold",
                !(@empresa_seleccionada && @empresa_seleccionada.id == empresa.id) && "text-gray-700 hover:bg-gray-50"
              ]}
            >
              {empresa.nombre}
            </button>
          </div>
        </div>

        <div class="w-72 flex-shrink-0 border border-gray-200 rounded-xl overflow-hidden" style="height: 75vh">
          <div class="px-3 py-2 border-b border-gray-100 flex items-center justify-between">
            <span class="text-xs font-bold text-gray-500 uppercase">Sucursales</span>
            <button :if={@empresa_seleccionada} type="button" phx-click="nueva_branch" class="text-purple-600 text-xs font-semibold hover:underline">
              + Nueva
            </button>
          </div>

          <p :if={!@empresa_seleccionada} class="text-xs text-gray-400 p-3">Elegí una empresa.</p>

          <div :if={@empresa_seleccionada} class="overflow-y-auto" style="height: calc(75vh - 36px)">
            <div :if={@branch_form} class="p-3 border-b border-gray-100 bg-gray-50">
              <.form for={@branch_form} phx-submit="guardar_branch" class="space-y-2">
                <input type="text" name={@branch_form[:branch_name].name} value={@branch_form[:branch_name].value}
                  placeholder="Nombre de la sucursal" class="w-full border border-gray-300 rounded-lg px-2 py-1 text-sm" />
                <p :if={@branch_form[:branch_name].errors != []} class="text-[11px] text-red-600">{elem(hd(@branch_form[:branch_name].errors), 0)}</p>
                <div class="flex gap-2">
                  <button type="submit" class="px-2 py-1 rounded-lg bg-purple-600 text-white text-xs font-semibold">Guardar</button>
                  <button type="button" phx-click="cerrar_branch_form" class="px-2 py-1 rounded-lg border border-gray-300 text-xs">Cancelar</button>
                </div>
              </.form>
            </div>

            <button
              :for={branch <- @branches}
              type="button"
              phx-click="seleccionar_branch"
              phx-value-id={branch.id}
              class={[
                "w-full text-left px-3 py-2 text-sm border-b border-gray-50",
                @branch_seleccionada && @branch_seleccionada.id == branch.id && "bg-purple-50 text-purple-700 font-semibold",
                !(@branch_seleccionada && @branch_seleccionada.id == branch.id) && "text-gray-700 hover:bg-gray-50"
              ]}
            >
              {branch.branch_name}
            </button>

            <p :if={@branches == []} class="text-xs text-gray-400 p-3">Sin sucursales todavía.</p>
          </div>
        </div>

        <div class="flex-1 border border-gray-200 rounded-xl p-4" style="min-height: 75vh">
          <p :if={!@branch_seleccionada} class="text-sm text-gray-400">Elegí una sucursal para ver sus unidades de venta y ubicaciones de inventario.</p>

          <div :if={@branch_seleccionada} class="grid grid-cols-2 gap-4">
            <div class="border border-gray-200 rounded-lg p-3">
              <div class="flex items-center justify-between mb-2">
                <h2 class="text-sm font-bold text-gray-900">Unidades de venta</h2>
                <button type="button" phx-click="nueva_sales_unit" class="text-purple-600 text-xs font-semibold hover:underline">+ Nueva</button>
              </div>

              <div :if={@sales_unit_form} class="p-3 mb-2 border border-gray-200 rounded-lg bg-gray-50">
                <.form for={@sales_unit_form} phx-submit="guardar_sales_unit" class="space-y-2">
                  <input type="text" name={@sales_unit_form[:sales_unit_name].name} value={@sales_unit_form[:sales_unit_name].value}
                    placeholder="Nombre (ej. Preventa 1)" class="w-full border border-gray-300 rounded-lg px-2 py-1 text-sm" />
                  <input type="text" name={@sales_unit_form[:sales_unit_type].name} value={@sales_unit_form[:sales_unit_type].value}
                    placeholder="Tipo (ej. preventa, autoventas, pdv, call center)" class="w-full border border-gray-300 rounded-lg px-2 py-1 text-sm" />
                  <p :if={@sales_unit_form[:sales_unit_name].errors != []} class="text-[11px] text-red-600">{elem(hd(@sales_unit_form[:sales_unit_name].errors), 0)}</p>
                  <div class="flex gap-2">
                    <button type="submit" class="px-2 py-1 rounded-lg bg-purple-600 text-white text-xs font-semibold">Guardar</button>
                    <button type="button" phx-click="cerrar_sales_unit_form" class="px-2 py-1 rounded-lg border border-gray-300 text-xs">Cancelar</button>
                  </div>
                </.form>
              </div>

              <div :for={su <- @sales_units} class="flex items-center justify-between px-2 py-1.5 text-sm border-b border-gray-50">
                <div>
                  <span>{su.sales_unit_name}</span>
                  <span :if={su.sales_unit_type} class="text-[11px] text-gray-400 ml-1">({su.sales_unit_type})</span>
                </div>
                <button type="button" phx-click="eliminar_sales_unit" phx-value-id={su.id}
                  data-confirm={"¿Eliminar \"#{su.sales_unit_name}\"?"} class="text-red-500 text-xs hover:underline">
                  Eliminar
                </button>
              </div>
              <p :if={@sales_units == []} class="text-xs text-gray-400">Sin unidades de venta todavía.</p>
            </div>

            <div class="border border-gray-200 rounded-lg p-3">
              <div class="flex items-center justify-between mb-2">
                <h2 class="text-sm font-bold text-gray-900">Ubicaciones de inventario</h2>
                <button type="button" phx-click="nueva_inventory_location" class="text-purple-600 text-xs font-semibold hover:underline">+ Nueva</button>
              </div>

              <div :if={@inventory_location_form} class="p-3 mb-2 border border-gray-200 rounded-lg bg-gray-50">
                <.form for={@inventory_location_form} phx-submit="guardar_inventory_location" class="space-y-2">
                  <input type="text" name={@inventory_location_form[:inventory_name].name} value={@inventory_location_form[:inventory_name].value}
                    placeholder="Nombre (ej. Producto terminado)" class="w-full border border-gray-300 rounded-lg px-2 py-1 text-sm" />
                  <input type="text" name={@inventory_location_form[:inventory_type].name} value={@inventory_location_form[:inventory_type].value}
                    placeholder="Tipo (ej. planta, punto de embarque, almacén)" class="w-full border border-gray-300 rounded-lg px-2 py-1 text-sm" />
                  <input type="text" name={@inventory_location_form[:inventory_function].name} value={@inventory_location_form[:inventory_function].value}
                    placeholder="Función (ej. comprometida, producto terminado, producción)" class="w-full border border-gray-300 rounded-lg px-2 py-1 text-sm" />
                  <p :if={@inventory_location_form[:inventory_name].errors != []} class="text-[11px] text-red-600">{elem(hd(@inventory_location_form[:inventory_name].errors), 0)}</p>
                  <div class="flex gap-2">
                    <button type="submit" class="px-2 py-1 rounded-lg bg-purple-600 text-white text-xs font-semibold">Guardar</button>
                    <button type="button" phx-click="cerrar_inventory_location_form" class="px-2 py-1 rounded-lg border border-gray-300 text-xs">Cancelar</button>
                  </div>
                </.form>
              </div>

              <div :for={il <- @inventory_locations} class="flex items-center justify-between px-2 py-1.5 text-sm border-b border-gray-50">
                <div>
                  <span>{il.inventory_name}</span>
                  <span :if={il.inventory_type} class="text-[11px] text-gray-400 ml-1">({il.inventory_type})</span>
                </div>
                <button type="button" phx-click="eliminar_inventory_location" phx-value-id={il.id}
                  data-confirm={"¿Eliminar \"#{il.inventory_name}\"?"} class="text-red-500 text-xs hover:underline">
                  Eliminar
                </button>
              </div>
              <p :if={@inventory_locations == []} class="text-xs text-gray-400">Sin ubicaciones de inventario todavía.</p>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
