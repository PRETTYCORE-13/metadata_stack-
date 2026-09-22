defmodule MetadataAppWeb.Sysadmin.PropagacionLive do
  @moduledoc """
  "Propagación" (SPEC-SYS-1809202603) — línea de tiempo de commits de
  `origin/main` con, superpuesto, en qué commit está parado cada
  canal/sistema ahora mismo (R9), estilo lista de ejecuciones de GitHub
  Actions. Grupo F: además de solo-lectura (Grupo E), permite disparar
  una propagación puntual (R8, elegir commit + destino) o un rollback de
  UN paso (R10, "volver a la versión anterior") directo desde acá.

  Todo sale en vivo de `MetadataApp.PropagacionContext` (git + k3s vía
  SSH + GitHub Actions) -- nunca de una tabla propia (R9a). Disparar
  reusa `MotorAlta.imagen_para_commit/1` +
  `MotorAlta.disparar_actualizacion/4` tal cual -- ningún camino nuevo
  de despliegue, la pantalla es una UI sobre el mismo mecanismo del CLI.
  """

  use MetadataAppWeb, :live_view_admin

  on_mount {MetadataAppWeb.UsuarioAuth, :mount_current_scope}
  on_mount {MetadataAppWeb.Hooks.Autorizacion, {"sysadmin_propagacion", "leer"}}

  alias MetadataApp.Ambientes
  alias MetadataApp.MotorAlta
  alias MetadataApp.PropagacionContext
  alias MetadataApp.PropagacionContext.SeguridadMigracion
  alias MetadataAppWeb.AdminNav

  @menu [
    %{tipo: :pagina, id: "bc_list", label: "BC List", nav: "/sysadmin/bc-list"},
    %{tipo: :pagina, id: "buscar_trn", label: "Buscar TRN", nav: "/sysadmin/buscar-trn"},
    %{tipo: :pagina, id: "tepache", label: "Tepache Exp/Imp", nav: "/sysadmin/tepache"},
    %{tipo: :pagina, id: "roles", label: "Roles y Usuarios", nav: "/sysadmin/roles"},
    %{tipo: :pagina, id: "usuarios_empresa", label: "Usuarios", nav: "/sysadmin/usuarios"},
    %{tipo: :pagina, id: "empresas", label: "Empresas", nav: "/sysadmin/empresas"},
    %{tipo: :pagina, id: "credenciales", label: "Credenciales", nav: "/sysadmin/credenciales"},
    %{tipo: :pagina, id: "ambientes", label: "Ambientes de Deploy", nav: "/sysadmin/ambientes"},
    %{tipo: :pagina, id: "acciones_externas", label: "Acciones externas", nav: "/sysadmin/acciones-externas"},
    %{tipo: :pagina, id: "jerarquia", label: "Jerarquía organizacional", nav: "/sysadmin/jerarquia"},
    %{tipo: :pagina, id: "panel_control", label: "Panel Control", nav: "/sysadmin/panel-control"},
    %{tipo: :pagina, id: "sesiones_movil", label: "Sesiones móviles", nav: "/sysadmin/sesiones-movil"},
    %{tipo: :pagina, id: "endpoints", label: "Endpoints", nav: "/sysadmin/endpoints"},
    %{tipo: :pagina, id: "propagacion", label: "Propagación", nav: "/sysadmin/propagacion"}
  ]

  def mount(_params, _session, socket) do
    ambientes = Ambientes.listar_ambientes()
    ambiente_seleccionado = if length(ambientes) == 1, do: hd(ambientes), else: nil
    clientes = MotorAlta.leer_sistemas() |> Map.keys()

    socket =
      socket
      |> assign(:current_page, "propagacion")
      |> assign(:menu_items, AdminNav.filtrar_menu(@menu))
      |> assign(:sidebar_open, false)
      |> assign(:show_programacion_children, false)
      |> assign(:show_clientes_children, false)
      |> assign(:show_prettycore_children, false)
      |> assign(:ambientes, ambientes)
      |> assign(:ambiente_seleccionado, ambiente_seleccionado)
      |> assign(:clientes, clientes)
      |> assign(:commits, nil)
      |> assign(:cargando, false)
      |> assign(:error_carga, nil)
      |> assign(:commit_expandido, nil)

    {:ok, if(ambiente_seleccionado, do: iniciar_carga(socket), else: socket)}
  end

  def handle_event("change_page", %{"id" => id}, socket) do
    AdminNav.handle_nav(id, socket, "propagacion")
  end

  def handle_event("elegir_ambiente", %{"ambiente_id" => ""}, socket) do
    {:noreply, socket |> assign(:ambiente_seleccionado, nil) |> assign(:commits, nil)}
  end

  def handle_event("elegir_ambiente", %{"ambiente_id" => id}, socket) do
    ambiente = Enum.find(socket.assigns.ambientes, &(&1.id == String.to_integer(id)))
    {:noreply, iniciar_carga(assign(socket, :ambiente_seleccionado, ambiente))}
  end

  def handle_event("actualizar", _params, socket) do
    {:noreply, iniciar_carga(socket)}
  end

  def handle_event("toggle_picker", %{"hash" => hash}, socket) do
    nuevo = if socket.assigns.commit_expandido == hash, do: nil, else: hash
    {:noreply, assign(socket, :commit_expandido, nuevo)}
  end

  def handle_event("propagar", %{"hash" => hash, "destino" => destino}, socket) do
    {:noreply, socket |> assign(:commit_expandido, nil) |> disparar(destino, hash)}
  end

  def handle_event("rollback", %{"hash" => hash, "destino" => destino}, socket) do
    case PropagacionContext.commit_anterior(socket.assigns.commits, hash) do
      nil ->
        {:noreply, put_flash(socket, :error, "No hay un commit anterior cargado en esta línea de tiempo -- aumentá el límite para verlo.")}

      anterior ->
        {:noreply, disparar_rollback(socket, destino, hash, anterior.hash)}
    end
  end

  # Propagación puntual (R8, elegir commit + destino) -- SIN rollback de
  # base de datos: mover un destino HACIA ADELANTE a un commit ya
  # validado no tiene "migraciones que revertir", el `/app/bin/setup`
  # que ya corre `actualizar-sistema.yml` en cada deploy se encarga de
  # migrar hacia adelante como siempre.
  defp disparar(socket, destino, hash) do
    ambiente = socket.assigns.ambiente_seleccionado

    case MotorAlta.imagen_para_commit(hash) do
      {:error, mensaje} ->
        put_flash(socket, :error, mensaje)

      {:ok, imagen} ->
        case MotorAlta.disparar_actualizacion(ambiente, destino, imagen) do
          {:ok, :sin_cambios, mensaje} ->
            put_flash(socket, :info, mensaje)

          {:ok, _salida} ->
            socket
            |> put_flash(:info, "Disparado -- \"#{destino}\" va camino a #{imagen}. Seguí el progreso con \"gh run list\".")
            |> iniciar_carga()

          {:error, mensaje} ->
            put_flash(socket, :error, mensaje)
        end
    end
  end

  # Rollback (R10) -- SÍ evalúa base de datos (R10a/R10b, Grupo H):
  # primero el código (mismo camino que disparar/3), y solo si eso
  # funcionó, decide qué hacer con la base -- "primero código, después
  # base" (design.md §6.3, confirmado con el usuario).
  defp disparar_rollback(socket, destino, hash_actual, hash_destino) do
    ambiente = socket.assigns.ambiente_seleccionado

    case MotorAlta.imagen_para_commit(hash_destino) do
      {:error, mensaje} ->
        put_flash(socket, :error, mensaje)

      {:ok, imagen} ->
        case MotorAlta.disparar_actualizacion(ambiente, destino, imagen) do
          {:ok, :sin_cambios, mensaje} ->
            put_flash(socket, :info, mensaje)

          {:ok, _salida} ->
            socket
            |> put_flash(:info, "Código revertido -- \"#{destino}\" va camino a #{imagen}.")
            |> evaluar_rollback_base_datos(ambiente, destino, hash_destino, hash_actual)
            |> iniciar_carga()

          {:error, mensaje} ->
            put_flash(socket, :error, mensaje)
        end
    end
  end

  defp evaluar_rollback_base_datos(socket, ambiente, destino, hash_destino, hash_actual) do
    case PropagacionContext.migraciones_entre(hash_destino, hash_actual) do
      [] ->
        socket

      rutas ->
        case SeguridadMigracion.clasificar_conjunto(rutas, {:remoto, ambiente, destino}) do
          {:automatico, _operaciones} ->
            case MotorAlta.rollback_base_datos(ambiente, destino, rutas) do
              {:ok, _salida} ->
                put_flash(socket, :info, "Base de datos revertida automáticamente -- rollback completo (código + datos).")

              {:error, mensaje} ->
                put_flash(socket, :error, "El código se revirtió, pero el rollback de base de datos falló: #{mensaje}")
            end

          {:manual, motivo, _bloqueante} ->
            put_flash(
              socket,
              :error,
              "Código revertido. La base de datos NO se revirtió automáticamente -- #{motivo} Revertir el schema a mano queda como responsabilidad del administrador."
            )
        end
    end
  end

  def handle_async(:cargar_linea_de_tiempo, {:ok, commits}, socket) do
    {:noreply, socket |> assign(:commits, commits) |> assign(:cargando, false) |> assign(:error_carga, nil)}
  end

  def handle_async(:cargar_linea_de_tiempo, {:exit, motivo}, socket) do
    {:noreply,
     socket
     |> assign(:cargando, false)
     |> assign(:error_carga, "No se pudo cargar la línea de tiempo: #{inspect(motivo)}")}
  end

  defp iniciar_carga(socket) do
    ambiente = socket.assigns.ambiente_seleccionado

    socket
    |> assign(:cargando, true)
    |> assign(:error_carga, nil)
    |> start_async(:cargar_linea_de_tiempo, fn -> PropagacionContext.linea_de_tiempo(ambiente) end)
  end

  defp estado_icono(%{runs: []}), do: {"radio_button_unchecked", "text-gray-300"}
  defp estado_icono(%{runs: runs}) do
    case Enum.at(runs, 0) do
      %{estado: "success"} -> {"check_circle", "text-green-600"}
      %{estado: estado} when estado in ["failure", "cancelled", "timed_out"] -> {"cancel", "text-red-600"}
      _ -> {"pending", "text-amber-500"}
    end
  end

  defp actor_run(%{runs: []}), do: nil
  defp actor_run(%{runs: [run | _]}), do: run

  def render(assigns) do
    ~H"""
    <div class="p-6">
      <div class="flex items-center gap-2 mb-4">
        <.link navigate={~p"/"} title="Volver al inicio"
          class="w-7 h-7 flex items-center justify-center rounded-lg text-gray-500 hover:bg-gray-100 hover:text-gray-700 transition-colors shrink-0">
          <span class="material-symbols-outlined" style="font-size: 18px">arrow_back</span>
        </.link>
        <div>
          <h1 class="text-2xl font-bold">Propagación</h1>
          <p class="text-xs text-gray-400">Línea de tiempo de commits + qué canal/sistema está parado en cada uno — todo en vivo, sin registro propio.</p>
        </div>
      </div>

      <div class="flex items-center gap-3 mb-4">
        <select name="ambiente_id" phx-change="elegir_ambiente" class="border border-gray-300 rounded-lg px-2 py-1.5 text-sm">
          <option value="" selected={is_nil(@ambiente_seleccionado)}>Elegí un ambiente...</option>
          <option :for={a <- @ambientes} value={a.id} selected={@ambiente_seleccionado && @ambiente_seleccionado.id == a.id}>
            {a.nombre} ({a.host})
          </option>
        </select>

        <button
          :if={@ambiente_seleccionado}
          type="button"
          phx-click="actualizar"
          disabled={@cargando}
          class="px-3 py-1.5 rounded-lg bg-purple-600 text-white text-sm font-semibold hover:bg-purple-700 disabled:opacity-50"
        >
          {if @cargando, do: "Actualizando...", else: "Actualizar"}
        </button>
      </div>

      <p :if={is_nil(@ambiente_seleccionado)} class="text-sm text-gray-400">
        Elegí un ambiente para ver la línea de tiempo.
      </p>

      <p :if={@error_carga} class="text-sm text-red-600 mb-3">{@error_carga}</p>

      <div :if={@ambiente_seleccionado && @cargando && is_nil(@commits)} class="text-sm text-gray-400">
        Consultando git + k3s + GitHub Actions...
      </div>

      <div :if={@commits} class="border border-gray-200 rounded-xl divide-y divide-gray-100">
        <div :for={commit <- @commits} class="px-4 py-3">
          <div class="flex items-start gap-3">
            <span class={["material-symbols-outlined mt-0.5", elem(estado_icono(commit), 1)]} style="font-size: 20px">
              {elem(estado_icono(commit), 0)}
            </span>

            <div class="flex-1 min-w-0">
              <div class="flex items-center gap-2 flex-wrap">
                <span class="text-sm font-medium text-gray-900 truncate">{commit.mensaje}</span>
                <span class="text-[11px] font-mono text-gray-400">{commit.hash_corto}</span>
              </div>

              <div class="text-[11px] text-gray-500 mt-0.5">
                autor: <span class="font-medium">{commit.autor}</span>
                <%= if run = actor_run(commit) do %>
                  · corrido por GitHub Actions ({run.titulo || "actualizar-sistema.yml"}) · {run.creado_en}
                <% end %>
              </div>

              <div :if={commit.posiciones != []} class="flex items-center gap-1 flex-wrap mt-1.5">
                <span :for={destino <- Enum.sort(commit.posiciones)} class="inline-flex items-center gap-1 pl-2 pr-1 py-0.5 rounded-full bg-purple-50 text-purple-700 text-[11px] font-semibold">
                  {destino}
                  <button
                    :if={(anterior = PropagacionContext.commit_anterior(@commits, commit.hash)) && PropagacionContext.destino_ofrecible?(anterior, destino)}
                    type="button"
                    phx-click="rollback"
                    phx-value-hash={commit.hash}
                    phx-value-destino={destino}
                    data-confirm={"¿Volver \"#{destino}\" a la versión anterior (#{PropagacionContext.commit_anterior(@commits, commit.hash).hash_corto})?"}
                    title="Volver a la versión anterior"
                    class="w-4 h-4 flex items-center justify-center rounded-full hover:bg-purple-200"
                  >
                    <span class="material-symbols-outlined" style="font-size: 12px">undo</span>
                  </button>
                </span>
              </div>
            </div>

            <button
              type="button"
              phx-click="toggle_picker"
              phx-value-hash={commit.hash}
              class="text-[11px] text-purple-600 hover:underline shrink-0"
            >
              Propagar...
            </button>
          </div>

          <div :if={@commit_expandido == commit.hash} class="mt-2 ml-8 pl-2 border-l-2 border-purple-100">
            <p :if={PropagacionContext.destinos_ofrecibles(commit, @clientes) == []} class="text-[11px] text-gray-400">
              Este commit todavía no está en ningún canal predecesor -- nada disponible para propagar desde acá.
            </p>
            <div :if={PropagacionContext.destinos_ofrecibles(commit, @clientes) != []} class="flex items-center gap-2 flex-wrap">
              <button
                :for={destino <- PropagacionContext.destinos_ofrecibles(commit, @clientes)}
                type="button"
                phx-click="propagar"
                phx-value-hash={commit.hash}
                phx-value-destino={destino}
                data-confirm={"¿Propagar el commit #{commit.hash_corto} a \"#{destino}\"?"}
                class="px-2 py-1 rounded-lg border border-purple-300 text-purple-700 text-[11px] font-semibold hover:bg-purple-50"
              >
                → {destino}
              </button>
            </div>
          </div>
        </div>

        <p :if={@commits == []} class="text-sm text-gray-400 px-4 py-3">Sin commits para mostrar.</p>
      </div>
    </div>
    """
  end
end
