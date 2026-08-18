defmodule MetadataAppWeb.CambiarUnidadOperativaModal do
  use MetadataAppWeb, :live_component

  alias MetadataApp.Autenticacion
  alias MetadataApp.Permissions

  # Mismo motivo que ConfiguracionCuentaModal: estilos explícitos, no
  # clases de daisyUI (dependen del theme activo de la página de atrás y
  # quedaban ilegibles sobre este modal blanco).
  @campo_class "w-full rounded-lg border border-gray-300 bg-white px-3 py-2 text-sm text-gray-900 focus:border-purple-500 focus:outline-none focus:ring-2 focus:ring-purple-100"
  @boton_class "w-full rounded-lg bg-black hover:bg-gray-800 text-white font-semibold text-sm px-4 py-2.5 transition-colors disabled:opacity-60"

  # Fase 2/3 de UI/cambio-unidad-operativa (2026-08-15) -- contraparte del
  # footer, que desde Fase 1 pasó a ser SOLO LECTURA. Antes, cambiar la
  # Unidad Operativa disparaba una activación real POR CADA <select> que
  # se tocaba (Empresa, después Sucursal, después Almacén...), cada uno un
  # POST/redirect independiente. Acá los 4 niveles viven en el ESTADO DEL
  # COMPONENTE mientras el usuario elige -- nada se activa de verdad hasta
  # que aprieta "Aceptar", que dispara un POST real (LiveView no puede
  # escribir la sesión HTTP directo) contra
  # UnidadOperativaSessionController.activar/2, las 4 dimensiones juntas.
  #
  # Solo Empresa y Sucursal llevan phx-change: son las únicas que cambian
  # qué opciones se ofrecen MÁS ABAJO en la cadena. Almacén y Unidad de
  # Venta son hojas (nada depende de ellas), así que el <select> nativo
  # alcanza -- lo que el usuario haya dejado marcado ahí viaja tal cual en
  # el POST final, sin necesidad de reflejarlo en el estado del LiveView.
  #
  # Tras aceptar, el controller redirige (misma página de origen) -- la
  # recarga completa hace que MetadataAppWeb.UnidadOperativaWatcher (hook
  # ya existente en app.js) detecte el cambio de firma y muestre solo el
  # modal de reloj, sin que este componente tenga que saber que existe.
  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign(:campo_class, @campo_class)
     |> assign(:boton_class, @boton_class)
     |> assign_new(:abierto, fn -> false end)
     |> assign_new(:empresas, fn -> [] end)
     |> assign_new(:empresa_id, fn -> nil end)
     |> assign_new(:es_administrador?, fn -> false end)
     |> assign_new(:branches, fn -> [] end)
     |> assign_new(:branch_id, fn -> nil end)
     |> assign_new(:inventory_locations, fn -> [] end)
     |> assign_new(:inventory_id, fn -> nil end)
     |> assign_new(:sales_units, fn -> [] end)
     |> assign_new(:sales_unit_id, fn -> nil end)}
  end

  def handle_event("abrir", _params, socket) do
    %{usuario: usuario, empresa_activa: empresa_activa} = socket.assigns.current_scope

    empresas = Autenticacion.empresas_de_usuario(usuario.id)
    empresa_id = (empresa_activa && empresa_activa.id) || primer_id(empresas)
    es_administrador? = empresa_id && Permissions.administrador?(usuario.id, empresa_id)

    {:noreply,
     socket
     |> assign(:abierto, true)
     |> assign(:empresas, empresas)
     |> assign(:empresa_id, empresa_id)
     |> assign(:es_administrador?, es_administrador?)
     |> recalcular_branches(preferido: socket.assigns.current_scope.branch_activo && socket.assigns.current_scope.branch_activo.id)
     |> recalcular_inventario(
       preferido_inventory: socket.assigns.current_scope.inventory_location_activo && socket.assigns.current_scope.inventory_location_activo.id,
       preferido_sales_unit: socket.assigns.current_scope.sales_unit_activo && socket.assigns.current_scope.sales_unit_activo.id
     )}
  end

  def handle_event("cerrar", _params, socket) do
    {:noreply, assign(socket, :abierto, false)}
  end

  def handle_event("elegir_empresa", %{"empresa_id" => empresa_id}, socket) do
    usuario_id = socket.assigns.current_scope.usuario.id

    case Integer.parse(empresa_id) do
      {empresa_id, ""} ->
        es_administrador? = Permissions.administrador?(usuario_id, empresa_id)

        {:noreply,
         socket
         |> assign(:empresa_id, empresa_id)
         |> assign(:es_administrador?, es_administrador?)
         |> recalcular_branches([])
         |> recalcular_inventario([])}

      :error ->
        {:noreply, socket}
    end
  end

  def handle_event("elegir_branch", %{"branch_id" => branch_id}, socket) do
    case Integer.parse(branch_id) do
      {branch_id, ""} ->
        {:noreply,
         socket
         |> assign(:branch_id, branch_id)
         |> recalcular_inventario([])}

      :error ->
        {:noreply, socket}
    end
  end

  defp primer_id([]), do: nil
  defp primer_id([%{id: id} | _]), do: id

  defp recalcular_branches(socket, opts) do
    %{current_scope: %{usuario: usuario}, empresa_id: empresa_id, es_administrador?: es_administrador?} = socket.assigns

    branches = empresa_id && Autenticacion.branches_operables(usuario.id, empresa_id, es_administrador?)
    branches = branches || []
    preferido = Keyword.get(opts, :preferido)
    branch_id = if preferido && Enum.any?(branches, &(&1.id == preferido)), do: preferido, else: primer_id(branches)

    socket |> assign(:branches, branches) |> assign(:branch_id, branch_id)
  end

  defp recalcular_inventario(socket, opts) do
    %{current_scope: %{usuario: usuario}, empresa_id: empresa_id, branch_id: branch_id, es_administrador?: es_administrador?} = socket.assigns

    if branch_id do
      inventory_locations = Autenticacion.inventory_locations_operables(usuario.id, empresa_id, branch_id, es_administrador?)
      sales_units = Autenticacion.sales_units_operables(usuario.id, empresa_id, branch_id, es_administrador?)

      preferido_inventory = Keyword.get(opts, :preferido_inventory)
      preferido_sales_unit = Keyword.get(opts, :preferido_sales_unit)

      inventory_id =
        if preferido_inventory && Enum.any?(inventory_locations, &(&1.id == preferido_inventory)),
          do: preferido_inventory,
          else: primer_id(inventory_locations)

      sales_unit_id =
        if preferido_sales_unit && Enum.any?(sales_units, &(&1.id == preferido_sales_unit)), do: preferido_sales_unit, else: nil

      socket
      |> assign(:inventory_locations, inventory_locations)
      |> assign(:inventory_id, inventory_id)
      |> assign(:sales_units, sales_units)
      |> assign(:sales_unit_id, sales_unit_id)
    else
      socket
      |> assign(:inventory_locations, [])
      |> assign(:inventory_id, nil)
      |> assign(:sales_units, [])
      |> assign(:sales_unit_id, nil)
    end
  end

  def render(assigns) do
    ~H"""
    <div id={@id}>
      <div :if={@abierto} class="fixed inset-0 bg-black/50 flex items-center justify-center z-[200] p-4">
        <div class="fixed inset-0" phx-click="cerrar" phx-target={@myself} />
        <div class="relative bg-white rounded-2xl shadow-2xl max-w-md w-full max-h-[85vh] overflow-y-auto">
          <div class="bg-black px-6 pt-6 pb-5 rounded-t-2xl relative">
            <button
              type="button"
              phx-click="cerrar"
              phx-target={@myself}
              class="absolute top-4 right-4 w-7 h-7 flex items-center justify-center rounded-lg text-white/70 hover:bg-white/10 hover:text-white transition-colors shrink-0"
            >
              <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
                <line x1="18" y1="6" x2="6" y2="18" /><line x1="6" y1="6" x2="18" y2="18" />
              </svg>
            </button>
            <h2 class="text-white font-bold text-base">Cambiar Unidad Operativa</h2>
            <p class="text-white/60 text-xs mt-1">Elegí empresa, sucursal, almacén y unidad de venta.</p>
          </div>

          <div class="px-6 py-5">
            <form
              method="post"
              action={~p"/meta_schema_usuario/unidad-operativa/activar"}
              class="space-y-4"
            >
              <input type="hidden" name="_csrf_token" value={Phoenix.Controller.get_csrf_token()} />

              <div>
                <label class="text-[11px] font-bold uppercase tracking-wide text-gray-400">Empresa</label>
                <select name="empresa_id" phx-change="elegir_empresa" phx-target={@myself} class={@campo_class}>
                  <option :for={empresa <- @empresas} value={empresa.id} selected={empresa.id == @empresa_id}>
                    {empresa.nombre}
                  </option>
                </select>
              </div>

              <div :if={@branches != []}>
                <label class="text-[11px] font-bold uppercase tracking-wide text-gray-400">Sucursal</label>
                <select name="branch_id" phx-change="elegir_branch" phx-target={@myself} class={@campo_class}>
                  <option :for={branch <- @branches} value={branch.id} selected={branch.id == @branch_id}>
                    {branch.branch_name}
                  </option>
                </select>
              </div>
              <p :if={@branches == []} class="text-sm text-gray-500 bg-gray-50 border border-gray-200 rounded-lg p-3">
                No tenés ninguna sucursal asignada en esta empresa.
              </p>

              <div :if={@branches != [] and @inventory_locations != []}>
                <label class="text-[11px] font-bold uppercase tracking-wide text-gray-400">Almacén</label>
                <select name="inventory_location_id" class={@campo_class}>
                  <option :for={inventory_location <- @inventory_locations} value={inventory_location.id} selected={inventory_location.id == @inventory_id}>
                    {inventory_location.inventory_name}
                  </option>
                </select>
              </div>
              <p :if={@branches != [] and @inventory_locations == []} class="text-sm text-gray-500 bg-gray-50 border border-gray-200 rounded-lg p-3">
                Esa sucursal no tiene ningún almacén asignado para vos.
              </p>

              <div :if={@branches != [] and @sales_units != []}>
                <label class="text-[11px] font-bold uppercase tracking-wide text-gray-400">Unidad de venta (opcional)</label>
                <select name="sales_unit_id" class={@campo_class}>
                  <option value="" selected={is_nil(@sales_unit_id)}>Ninguna</option>
                  <option :for={sales_unit <- @sales_units} value={sales_unit.id} selected={sales_unit.id == @sales_unit_id}>
                    {sales_unit.sales_unit_name}
                  </option>
                </select>
              </div>

              <button
                type="submit"
                class={@boton_class}
                disabled={@branches == [] or @inventory_locations == []}
              >
                Aceptar
              </button>
            </form>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
