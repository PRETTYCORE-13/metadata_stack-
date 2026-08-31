defmodule MetadataAppWeb.Sysadmin.NdtConfigLive do
  @moduledoc """
  Auditoría de NDT (Numeración de Documentos Transaccionales) —
  `ndt_numbering_audits`, solo lectura salvo "Anular". Ver
  `MetadataApp.NDT.Numbering` para el motor real.

  Los PERFILES de numeración ya no se administran acá (2026-08-31,
  reemplazado por el BC real "NDT Configuración" — carpeta Sistema/
  Transacciones, catálogo `pty_ndt_configuracion`, con su propio
  autómata Activo/Cancelado) — esta pantalla solo linkea para allá y
  se queda con la auditoría, que no tiene equivalente natural como BC
  (abarca TODOS los perfiles históricamente, incluidos los ya dados de
  baja o borrados).
  """

  use MetadataAppWeb, :live_view_admin

  on_mount {MetadataAppWeb.UsuarioAuth, :mount_current_scope}
  on_mount {MetadataAppWeb.Hooks.Autorizacion, {"sysadmin_ndt", "leer"}}

  import Ecto.Query
  alias MetadataApp.Repo
  alias MetadataApp.Autenticacion.{Empresa, Branch}
  alias MetadataApp.BusinessProcessBuilder.MetaSchema.Header
  alias MetadataApp.BusinessProcessBuilder.MetaSchemaContext
  alias MetadataApp.NDT.{Numbering, NumberingAudit}
  alias MetadataAppWeb.AdminNav

  @menu [
    %{tipo: :pagina, id: "bc_list", label: "BC List", nav: "/sysadmin/bc-list"},
    %{tipo: :pagina, id: "buscar_trn", label: "Buscar TRN", nav: "/sysadmin/buscar-trn"},
    %{tipo: :pagina, id: "ndt_config", label: "NDT Config", nav: "/sysadmin/ndt-config"},
    %{tipo: :pagina, id: "tepache", label: "Tepache Exp/Imp", nav: "/sysadmin/tepache"},
    %{tipo: :pagina, id: "roles", label: "Roles y Usuarios", nav: "/sysadmin/roles"},
    %{tipo: :pagina, id: "usuarios_empresa", label: "Usuarios", nav: "/sysadmin/usuarios"},
    %{tipo: :pagina, id: "empresas", label: "Empresas", nav: "/sysadmin/empresas"},
    %{tipo: :pagina, id: "credenciales", label: "Credenciales", nav: "/sysadmin/credenciales"},
    %{tipo: :pagina, id: "ambientes", label: "Ambientes de Deploy", nav: "/sysadmin/ambientes"},
    %{tipo: :pagina, id: "acciones_externas", label: "Acciones externas", nav: "/sysadmin/acciones-externas"},
    %{tipo: :pagina, id: "jerarquia", label: "Jerarquía organizacional", nav: "/sysadmin/jerarquia"},
    %{tipo: :pagina, id: "panel_control", label: "Panel Control", nav: "/sysadmin/panel-control"}
  ]

  def mount(_params, _session, socket) do
    nav_perfiles =
      case MetaSchemaContext.obtener_header_por_nombre("pty_ndt_configuracion") do
        nil -> nil
        header -> header.schema_context_nav
      end

    {:ok,
     socket
     |> assign(:current_page, "ndt_config")
     |> assign(:menu_items, AdminNav.filtrar_menu(@menu))
     |> assign(:sidebar_open, false)
     |> assign(:nav_perfiles, nav_perfiles)
     |> cargar_audits()}
  end

  def handle_event("change_page", %{"id" => id}, socket) do
    AdminNav.handle_nav(id, socket, "ndt_config")
  end

  def handle_event("anular_folio", %{"id" => id}, socket) do
    case Numbering.anular(String.to_integer(id)) do
      {:ok, _} -> {:noreply, cargar_audits(socket)}
      {:error, _} -> {:noreply, put_flash(socket, :error, "No se pudo anular ese folio.")}
    end
  end

  defp cargar_audits(socket) do
    audits =
      from(a in NumberingAudit,
        left_join: h in Header,
        on: h.id == a.meta_schema_header_id,
        left_join: e in Empresa,
        on: e.id == a.empresa_id,
        left_join: b in Branch,
        on: b.id == a.branch_id,
        order_by: [desc: a.inserted_at],
        limit: 100,
        select: %{audit: a, header_label: h.schema_context_label, empresa_nombre: e.nombre, branch_nombre: b.branch_name}
      )
      |> Repo.all()

    assign(socket, :audits, audits)
  end

  defp formatear_fecha(nil), do: "—"
  defp formatear_fecha(fecha), do: Calendar.strftime(fecha, "%Y-%m-%d %H:%M:%S UTC")

  def render(assigns) do
    ~H"""
    <div class="max-w-5xl mx-auto p-8">
      <div class="flex items-center justify-between mb-4">
        <div class="flex items-center gap-2">
          <.link navigate={~p"/"} title="Volver al inicio"
            class="w-7 h-7 flex items-center justify-center rounded-lg text-gray-500 hover:bg-gray-100 hover:text-gray-700 transition-colors shrink-0">
            <span class="material-symbols-outlined" style="font-size: 18px">arrow_back</span>
          </.link>
          <h1 class="text-2xl font-bold">NDT — Auditoría</h1>
        </div>
        <.link
          :if={@nav_perfiles}
          navigate={@nav_perfiles}
          class="pc-btn-secundario bg-linear-to-b from-white to-gray-100 hover:to-gray-200 border border-gray-100 text-gray-800 shadow-sm font-semibold text-xs px-4 py-1.5 rounded-full transition-colors inline-flex items-center gap-1"
        >
          <span class="material-symbols-outlined" style="font-size: 15px">settings</span>
          Configurar perfiles (NDT Configuración)
        </.link>
      </div>
      <p class="text-sm text-gray-500 mb-4">
        Historial de folios asignados por el motor de numeración (todos los perfiles, incluidos los ya dados de baja). Los perfiles en sí se administran desde el BC "NDT Configuración" (Sistema → Transacciones).
      </p>

      <.tabla_auditoria audits={@audits} />
    </div>
    """
  end

  attr :audits, :list, required: true

  defp tabla_auditoria(assigns) do
    ~H"""
    <div class="overflow-x-auto rounded-xl border border-gray-200">
      <table class="min-w-full divide-y divide-gray-200">
        <thead class="bg-gray-50">
          <tr>
            <th class="px-3 py-2 text-left text-xs font-semibold text-gray-500 uppercase tracking-wide">Folio</th>
            <th class="px-3 py-2 text-left text-xs font-semibold text-gray-500 uppercase tracking-wide">Tipo de documento</th>
            <th class="px-3 py-2 text-left text-xs font-semibold text-gray-500 uppercase tracking-wide">Organización</th>
            <th class="px-3 py-2 text-left text-xs font-semibold text-gray-500 uppercase tracking-wide">Unidad Operativa</th>
            <th class="px-3 py-2 text-left text-xs font-semibold text-gray-500 uppercase tracking-wide">TRN</th>
            <th class="px-3 py-2 text-left text-xs font-semibold text-gray-500 uppercase tracking-wide">Asignado</th>
            <th class="px-3 py-2 text-left text-xs font-semibold text-gray-500 uppercase tracking-wide">Estado</th>
            <th class="px-3 py-2"></th>
          </tr>
        </thead>
        <tbody class="divide-y divide-gray-100">
          <tr :for={fila <- @audits} class="hover:bg-purple-50/60">
            <td class="px-3 py-2 text-sm font-mono font-semibold text-gray-900">{fila.audit.folio}</td>
            <td class="px-3 py-2 text-sm text-gray-700">{fila.header_label}</td>
            <td class="px-3 py-2 text-sm text-gray-700">{fila.empresa_nombre}</td>
            <td class="px-3 py-2 text-sm text-gray-700">{fila.branch_nombre || "Centralizada"}</td>
            <td class="px-3 py-2 text-sm font-mono text-gray-500">{fila.audit.trn || "—"}</td>
            <td class="px-3 py-2 text-sm text-gray-500">{formatear_fecha(fila.audit.inserted_at)}</td>
            <td class="px-3 py-2">
              <span :if={is_nil(fila.audit.anulado_at)} class="inline-flex px-2 py-0.5 rounded-full text-xs font-semibold bg-green-50 text-green-700 border border-green-100">Vigente</span>
              <span :if={fila.audit.anulado_at} class="inline-flex px-2 py-0.5 rounded-full text-xs font-semibold bg-red-50 text-red-700 border border-red-100">Anulado</span>
            </td>
            <td class="px-3 py-2 text-right whitespace-nowrap">
              <button
                :if={is_nil(fila.audit.anulado_at)}
                type="button"
                phx-click="anular_folio"
                phx-value-id={fila.audit.id}
                data-confirm={"¿Anular el folio #{fila.audit.folio}? No se reutiliza -- solo queda marcado como anulado."}
                class="text-xs text-red-600 hover:underline"
              >
                Anular
              </button>
            </td>
          </tr>
          <tr :if={@audits == []}>
            <td colspan="8" class="px-4 py-6 text-center text-sm text-gray-400">Todavía no se asignó ningún folio.</td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end
end
