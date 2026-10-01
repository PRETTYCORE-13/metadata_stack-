defmodule MetadataAppWeb.Sysadmin.PurgarLive do
  @moduledoc """
  "Purgar" (SPEC-ARQ-3009202601) — retirar un artefacto `pty_*` de los
  builds futuros y purgarlo, ambiente por ambiente, como si nunca hubiera
  existido. Dos pestañas: Artefactos (qué está publicado y dónde existe)
  y Bitácora (quién purgó qué, dónde y cuándo).

  La lista nunca sale de la base local de quien abre la pantalla: sale de
  los releases de GitHub y de cada sistema destino (R2). Cada destino se
  consulta en paralelo; uno caído solo marca su columna (NF2).

  Todo lo que sale de la máquina pasa por `@fuente` (`MetadataApp.Purga`);
  las pruebas inyectan otra por la sesión (`"purga_fuente"`).
  """

  use MetadataAppWeb, :live_view_admin

  on_mount {MetadataAppWeb.UsuarioAuth, :mount_current_scope}
  on_mount {MetadataAppWeb.Hooks.Autorizacion, {"sysadmin_purgar", "leer"}}

  alias MetadataApp.{Ambientes, MotorAlta}
  alias MetadataApp.Workers.PurgaUnstableWorker
  alias MetadataAppWeb.AdminNav

  @pestanas [{"artefactos", "Artefactos", "inventory_2"}, {"bitacora", "Bitácora", "history"}]

  @menu [
    %{tipo: :pagina, id: "bc_list", label: "BC List", nav: "/sysadmin/bc-list"},
    %{tipo: :pagina, id: "buscar_trn", label: "Buscar TRN", nav: "/sysadmin/buscar-trn"},
    %{tipo: :pagina, id: "tepache", label: "Tepache Exp/Imp", nav: "/sysadmin/tepache"},
    %{tipo: :pagina, id: "roles", label: "Roles y Usuarios", nav: "/sysadmin/roles"},
    %{tipo: :pagina, id: "usuarios_empresa", label: "Usuarios", nav: "/sysadmin/usuarios"},
    %{tipo: :pagina, id: "empresas", label: "Empresas", nav: "/sysadmin/empresas"},
    %{tipo: :pagina, id: "credenciales", label: "Credenciales", nav: "/sysadmin/credenciales"},
    %{tipo: :pagina, id: "ambientes", label: "Ambientes de Deploy", nav: "/sysadmin/ambientes"},
    %{
      tipo: :pagina,
      id: "acciones_externas",
      label: "Acciones externas",
      nav: "/sysadmin/acciones-externas"
    },
    %{
      tipo: :pagina,
      id: "jerarquia",
      label: "Jerarquía organizacional",
      nav: "/sysadmin/jerarquia"
    },
    %{tipo: :pagina, id: "panel_control", label: "Panel Control", nav: "/sysadmin/panel-control"},
    %{
      tipo: :pagina,
      id: "sesiones_movil",
      label: "Sesiones móviles",
      nav: "/sysadmin/sesiones-movil"
    },
    %{tipo: :pagina, id: "endpoints", label: "Endpoints", nav: "/sysadmin/endpoints"},
    %{tipo: :pagina, id: "propagacion", label: "Propagación", nav: "/sysadmin/propagacion"},
    %{tipo: :pagina, id: "purgar", label: "Purgar", nav: "/sysadmin/purgar"}
  ]

  @etiquetas_tipo %{
    catalogo: "Catálogo",
    consulta: "Consulta",
    consulta_sql: "Consulta SQL",
    lapida: "Lápida"
  }

  def mount(_params, session, socket) do
    if connected?(socket),
      do: Phoenix.PubSub.subscribe(MetadataApp.PubSub, PurgaUnstableWorker.topico())

    ambientes = Ambientes.listar_ambientes()
    clientes = MotorAlta.leer_sistemas() |> Map.keys() |> Enum.sort()

    socket =
      socket
      |> assign(:current_page, "purgar")
      |> assign(:menu_items, AdminNav.filtrar_menu(@menu))
      |> assign(:sidebar_open, false)
      |> assign(:show_programacion_children, false)
      |> assign(:show_clientes_children, false)
      |> assign(:show_prettycore_children, false)
      |> assign(:pestanas, @pestanas)
      |> assign(:pestana, "artefactos")
      |> assign(:fuente, session["purga_fuente"] || MetadataApp.Purga)
      |> assign(:ambientes, ambientes)
      |> assign(:ambiente, if(length(ambientes) == 1, do: hd(ambientes)))
      |> assign(:destinos, MotorAlta.canales() ++ clientes)
      |> assign(:clientes, clientes)
      |> assign(:artefactos, nil)
      |> assign(:error_artefactos, nil)
      |> assign(:presencia, %{})
      |> assign(:modal, nil)
      |> assign(:en_curso, %{})
      |> assign(:limpiar_local, MapSet.new())
      |> assign(:bitacora_todas, nil)
      |> assign(:bitacora_errores, %{})
      |> assign(:bitacora_vacia, true)
      |> assign(:filtro, %{"artefacto" => "", "destino" => ""})
      |> stream_configure(:bitacora, dom_id: &"bit-#{&1["destino"]}-#{&1["id"]}")
      |> stream(:bitacora, [])

    {:ok, if(socket.assigns.ambiente && connected?(socket), do: cargar(socket), else: socket)}
  end

  def handle_params(params, _uri, socket) do
    pestana =
      if params["pestana"] in Enum.map(@pestanas, &elem(&1, 0)),
        do: params["pestana"],
        else: "artefactos"

    socket = assign(socket, :pestana, pestana)

    socket =
      if pestana == "bitacora" && socket.assigns.ambiente != nil &&
           is_nil(socket.assigns.bitacora_todas) && connected?(socket),
         do: cargar_bitacora(socket),
         else: socket

    {:noreply, socket}
  end

  ## Carga

  defp cargar(socket) do
    %{ambiente: ambiente, destinos: destinos, fuente: fuente} = socket.assigns

    socket =
      socket
      |> assign(:artefactos, nil)
      |> assign(:error_artefactos, nil)
      |> assign(:presencia, Map.new(destinos, &{&1, :cargando}))
      |> start_async(:artefactos, fn -> fuente.artefactos() end)

    Enum.reduce(destinos, socket, fn destino, s ->
      start_async(s, {:inventario, destino}, fn ->
        fuente.inventario_destino(ambiente, destino)
      end)
    end)
  end

  defp cargar_bitacora(socket) do
    %{ambiente: ambiente, destinos: destinos, fuente: fuente} = socket.assigns

    socket =
      socket |> assign(:bitacora_todas, []) |> assign(:bitacora_errores, %{}) |> aplicar_filtro()

    Enum.reduce(destinos, socket, fn destino, s ->
      start_async(s, {:bitacora, destino}, fn -> fuente.bitacora_destino(ambiente, destino) end)
    end)
  end

  def handle_async(:artefactos, {:ok, {:ok, artefactos}}, socket),
    do: {:noreply, assign(socket, :artefactos, artefactos)}

  def handle_async(:artefactos, {:ok, {:error, mensaje}}, socket),
    do: {:noreply, assign(socket, :error_artefactos, mensaje)}

  def handle_async(:artefactos, {:exit, motivo}, socket),
    do: {:noreply, assign(socket, :error_artefactos, inspect(motivo))}

  def handle_async({:inventario, destino}, resultado, socket) do
    estado =
      case resultado do
        {:ok, {:ok, inventario}} -> {:ok, inventario}
        {:ok, {:error, :sin_purga}} -> :sin_purga
        {:ok, {:error, mensaje}} -> {:error, mensaje}
        {:exit, motivo} -> {:error, inspect(motivo)}
      end

    {:noreply, update(socket, :presencia, &Map.put(&1, destino, estado))}
  end

  def handle_async({:bitacora, destino}, resultado, socket) do
    case resultado do
      {:ok, {:ok, registros}} ->
        nuevos = Enum.map(registros, &Map.put(&1, "destino", destino))
        {:noreply, socket |> update(:bitacora_todas, &((&1 || []) ++ nuevos)) |> aplicar_filtro()}

      {:ok, {:error, motivo}} ->
        {:noreply,
         update(socket, :bitacora_errores, &Map.put(&1, destino, motivo_legible(motivo)))}

      {:exit, motivo} ->
        {:noreply, update(socket, :bitacora_errores, &Map.put(&1, destino, inspect(motivo)))}
    end
  end

  def handle_async(:preparar, resultado, socket) do
    modal =
      case resultado do
        {:ok, {:ok, prep}} -> %{socket.assigns.modal | prep: prep, cargando: false}
        {:ok, {:error, mensaje}} -> %{socket.assigns.modal | error: mensaje, cargando: false}
        {:exit, motivo} -> %{socket.assigns.modal | error: inspect(motivo), cargando: false}
      end

    {:noreply, assign(socket, :modal, modal)}
  end

  def handle_async(accion, resultado, socket)
      when accion in [:retirar, :purgar, :borrar_inventario] do
    case resultado do
      {:ok, {:ok, datos}} ->
        mensaje = mensaje_exito(accion, datos, socket) <> limpiar_local_si_pidio(accion, socket)
        {:noreply, socket |> assign(:modal, nil) |> put_flash(:info, mensaje) |> recargar()}

      {:ok, :ok} ->
        {:noreply,
         socket
         |> assign(:modal, nil)
         |> put_flash(:info, mensaje_exito(accion, %{}, socket))
         |> recargar()}

      {:ok, {:error, mensaje}} ->
        {:noreply, fallo(socket, motivo_legible(mensaje))}

      {:exit, motivo} ->
        {:noreply, fallo(socket, inspect(motivo))}
    end
  end

  # Si el modal ya se cerró mientras corría la acción, el error va al flash.
  defp fallo(%{assigns: %{modal: nil}} = socket, mensaje), do: put_flash(socket, :error, mensaje)

  defp fallo(socket, mensaje),
    do: assign(socket, :modal, %{socket.assigns.modal | ejecutando: false, error: mensaje})

  defp recargar(socket) do
    socket
    |> cargar()
    |> assign(:bitacora_todas, nil)
    |> then(&if(&1.assigns.pestana == "bitacora", do: cargar_bitacora(&1), else: &1))
  end

  defp mensaje_exito(_accion, _datos, %{assigns: %{modal: nil}}), do: "Listo."
  defp mensaje_exito(:retirar, %{resultado: "sin_cambios"}, _socket), do: "Ya estaba retirado."

  defp mensaje_exito(:retirar, datos, s),
    do: "#{s.assigns.modal.nombre} retirado. #{Map.get(datos, :mensaje, "")}"

  defp mensaje_exito(:purgar, _datos, s),
    do: "#{s.assigns.modal.nombre} purgado en #{s.assigns.modal.destino}."

  defp mensaje_exito(:borrar_inventario, _datos, s),
    do: "Inventario de #{s.assigns.modal.nombre} borrado."

  # R14: la copia local se borra solo después de una purga remota exitosa.
  defp limpiar_local_si_pidio(
         :purgar,
         %{assigns: %{modal: %{limpiar_local: true, nombre: nombre}}} = socket
       ), do: limpiar_local(nombre, socket)

  defp limpiar_local_si_pidio(_accion, _socket), do: ""

  defp limpiar_local(nombre, socket) do
    case socket.assigns.fuente.purgar_local(nombre, socket.assigns.current_scope.usuario.email) do
      {:ok, %{archivos: n}} -> " También se borró de tu máquina (#{n} archivo(s))."
      {:error, motivo} -> " No se pudo borrar tu copia local: #{motivo_legible(motivo)}"
    end
  end

  defp motivo_legible(:sin_purga), do: "versión sin purga"
  defp motivo_legible(m) when is_binary(m), do: m
  defp motivo_legible(m), do: inspect(m)

  ## Avisos del trabajo de unstable

  def handle_info({:purga_unstable, nombre, :esperando_imagen, mensaje}, socket) do
    {:noreply, update(socket, :en_curso, &Map.put(&1, nombre, mensaje))}
  end

  def handle_info({:purga_unstable, nombre, estado, mensaje}, socket) do
    tipo = if estado == :purgado, do: :info, else: :error

    local =
      if estado == :purgado and MapSet.member?(socket.assigns.limpiar_local, nombre),
        do: limpiar_local(nombre, socket),
        else: ""

    {:noreply,
     socket
     |> update(:en_curso, &Map.delete(&1, nombre))
     |> update(:limpiar_local, &MapSet.delete(&1, nombre))
     |> put_flash(tipo, mensaje <> local)
     |> then(&if(&1.assigns.ambiente, do: recargar(&1), else: &1))}
  end

  ## Eventos

  def handle_event("change_page", %{"id" => id}, socket),
    do: AdminNav.handle_nav(id, socket, "purgar")

  def handle_event("elegir_ambiente", %{"ambiente_id" => ""}, socket) do
    {:noreply,
     socket |> assign(:ambiente, nil) |> assign(:artefactos, nil) |> assign(:presencia, %{})}
  end

  def handle_event("elegir_ambiente", %{"ambiente_id" => id}, socket) do
    ambiente = Enum.find(socket.assigns.ambientes, &(to_string(&1.id) == id))
    {:noreply, socket |> assign(:ambiente, ambiente) |> assign(:bitacora_todas, nil) |> cargar()}
  end

  def handle_event("actualizar", _params, socket), do: {:noreply, recargar(socket)}

  def handle_event("abrir_retiro", %{"nombre" => nombre}, socket) do
    {:noreply, assign(socket, :modal, modal(:retirar, nombre, nil))}
  end

  def handle_event("abrir_purga", %{"nombre" => nombre, "destino" => destino}, socket) do
    artefacto = artefacto(socket, nombre)
    un_paso = destino == "unstable" and artefacto != nil and not artefacto.retirado
    %{ambiente: ambiente, fuente: fuente} = socket.assigns

    {:noreply,
     socket
     |> assign(:modal, %{
       modal(:purgar, nombre, destino)
       | un_paso: un_paso,
         cargando: true,
         copia_local: fuente.copia_local?(nombre)
     })
     |> start_async(:preparar, fn ->
       fuente.preparar(nombre, destino, ambiente, antes_de_retirar: un_paso)
     end)}
  end

  def handle_event("abrir_borrar_inventario", %{"nombre" => nombre}, socket) do
    {:noreply, assign(socket, :modal, modal(:borrar_inventario, nombre, nil))}
  end

  def handle_event("cerrar_modal", _params, socket), do: {:noreply, assign(socket, :modal, nil)}

  def handle_event("validar_confirmacion", %{"confirmacion" => c}, socket) do
    {:noreply,
     update(
       socket,
       :modal,
       &%{
         &1
         | escrito: c["nombre"] || "",
           acepto_filas: c["acepto_filas"] == "true",
           limpiar_local: c["limpiar_local"] == "true"
       }
     )}
  end

  def handle_event("confirmar", _params, %{assigns: %{modal: modal}} = socket) do
    if puede_confirmar?(modal), do: ejecutar(modal, socket), else: {:noreply, socket}
  end

  def handle_event("filtrar_bitacora", %{"filtro" => filtro}, socket) do
    {:noreply,
     socket |> assign(:filtro, Map.take(filtro, ["artefacto", "destino"])) |> aplicar_filtro()}
  end

  defp ejecutar(%{tipo: :retirar, nombre: nombre} = modal, socket) do
    %{ambiente: ambiente, fuente: fuente} = socket.assigns
    email = socket.assigns.current_scope.usuario.email

    {:noreply,
     socket
     |> assign(:modal, %{modal | ejecutando: true, error: nil})
     |> start_async(:retirar, fn -> fuente.retirar(nombre, ambiente, email) end)}
  end

  defp ejecutar(%{tipo: :purgar, un_paso: true, nombre: nombre}, socket) do
    email = socket.assigns.current_scope.usuario.email
    filas = filas_modal(socket.assigns.modal)

    case socket.assigns.fuente.encolar_purga_unstable(
           nombre,
           socket.assigns.ambiente.id,
           email,
           filas
         ) do
      {:ok, _job} ->
        {:noreply,
         socket
         |> assign(:modal, nil)
         |> update(:en_curso, &Map.put(&1, nombre, "Retirando y reconstruyendo unstable…"))
         |> then(
           &if(socket.assigns.modal.limpiar_local,
             do: update(&1, :limpiar_local, fn s -> MapSet.put(s, nombre) end),
             else: &1
           )
         )
         |> put_flash(
           :info,
           "Purga de #{nombre} en unstable en curso. Se completa sola cuando la imagen nueva esté arriba."
         )}

      {:error, motivo} ->
        {:noreply,
         assign(socket, :modal, %{socket.assigns.modal | error: motivo_legible(motivo)})}
    end
  end

  defp ejecutar(%{tipo: :purgar, nombre: nombre, destino: destino} = modal, socket) do
    %{ambiente: ambiente, fuente: fuente} = socket.assigns
    email = socket.assigns.current_scope.usuario.email
    confirmacion = %{nombre: modal.escrito, filas: filas_modal(modal)}

    {:noreply,
     socket
     |> assign(:modal, %{modal | ejecutando: true, error: nil})
     |> start_async(:purgar, fn ->
       fuente.purgar(nombre, destino, ambiente, email, confirmacion)
     end)}
  end

  defp ejecutar(%{tipo: :borrar_inventario, nombre: nombre} = modal, socket) do
    fuente = socket.assigns.fuente
    presente_en = presente_en(socket, nombre)

    {:noreply,
     socket
     |> assign(:modal, %{modal | ejecutando: true, error: nil})
     |> start_async(:borrar_inventario, fn -> fuente.borrar_inventario(nombre, presente_en) end)}
  end

  ## Estado derivado

  defp modal(tipo, nombre, destino) do
    %{
      tipo: tipo,
      nombre: nombre,
      destino: destino,
      un_paso: false,
      prep: nil,
      cargando: false,
      ejecutando: false,
      error: nil,
      escrito: "",
      acepto_filas: false,
      copia_local: false,
      limpiar_local: false
    }
  end

  defp artefacto(socket, nombre),
    do: Enum.find(socket.assigns.artefactos || [], &(&1.nombre == nombre))

  defp filas_modal(%{prep: %{impacto: impacto}}), do: impacto["filas"] || 0
  defp filas_modal(_), do: 0

  # "Purgar en unstable" en un paso: la imagen todavía trae el artefacto
  # (es lo esperado, se reconstruye); solo las dependencias bloquean.
  defp bloqueo_modal(%{prep: nil}), do: nil

  defp bloqueo_modal(%{un_paso: true, prep: prep}),
    do: if(prep.impacto["dependencias"] in [nil, []], do: nil, else: prep.bloqueo)

  defp bloqueo_modal(%{prep: prep}), do: prep.bloqueo

  defp puede_confirmar?(%{ejecutando: true}), do: false
  defp puede_confirmar?(%{tipo: :purgar, prep: nil}), do: false

  defp puede_confirmar?(modal) do
    modal.escrito == modal.nombre and bloqueo_modal(modal) == nil and
      (filas_modal(modal) == 0 or modal.acepto_filas)
  end

  # Filas de la tabla: lo publicado o retirado, más lo que solo existe en
  # algún destino (sin release: no se puede retirar desde aquí).
  defp filas(artefactos, presencia) do
    conocidos = MapSet.new(artefactos, & &1.nombre)

    solo_en_destino =
      for {_d, {:ok, %{"unidades" => unidades}}} <- presencia,
          u <- unidades,
          not MapSet.member?(conocidos, u["maestro"]),
          uniq: true do
        %{
          nombre: u["maestro"],
          tipo: MetadataApp.Purga.Unidad.nombre_tipo(u["tipo"]),
          tablas: u["tablas"],
          paquetes: [],
          retirado: false,
          versiones: [],
          solo_en_destino: true
        }
      end

    Enum.sort_by(
      Enum.map(artefactos, &Map.put(&1, :solo_en_destino, false)) ++ solo_en_destino,
      & &1.nombre
    )
  end

  defp celda(artefacto, estado) do
    case estado do
      :cargando ->
        :cargando

      :sin_purga ->
        :sin_purga

      {:error, motivo} ->
        {:error, motivo}

      {:ok, inv} ->
        if MetadataApp.Purga.presente?(artefacto, inv),
          do: {:presente, filas_estimadas(artefacto, inv)},
          else: :ausente

      nil ->
        :cargando
    end
  end

  defp filas_estimadas(artefacto, %{"unidades" => unidades}) do
    case Enum.find(unidades, &(&1["maestro"] == artefacto.nombre)) do
      nil -> nil
      u -> u["filas_estimadas"]
    end
  end

  defp presente_en(socket, nombre) do
    a = artefacto(socket, nombre)

    for {d, {:ok, inv}} <- socket.assigns.presencia,
        a && MetadataApp.Purga.presente?(a, inv),
        do: d
  end

  # Borrar el inventario solo cuando todos los destinos respondieron y en
  # ninguno queda el artefacto (R4).
  defp puede_borrar_inventario?(artefacto, presencia) do
    artefacto.retirado and artefacto.paquetes == [] and
      Enum.all?(presencia, fn {_d, estado} -> match?({:ok, _}, estado) end) and
      not Enum.any?(presencia, fn {_d, {:ok, inv}} ->
        MetadataApp.Purga.presente?(artefacto, inv)
      end)
  end

  defp estado_fila(%{solo_en_destino: true}), do: {"Sin publicar", "bg-slate-100 text-slate-600"}
  defp estado_fila(%{paquetes: [_ | _]}), do: {"Publicado", "bg-emerald-50 text-emerald-700"}
  defp estado_fila(%{retirado: true}), do: {"Retirado", "bg-amber-50 text-amber-700"}
  defp estado_fila(_), do: {"—", "bg-slate-100 text-slate-500"}

  defp aplicar_filtro(socket) do
    %{"artefacto" => art, "destino" => dest} = socket.assigns.filtro

    registros =
      (socket.assigns.bitacora_todas || [])
      |> Enum.filter(&(art == "" or String.contains?(&1["artefacto"] || "", art)))
      |> Enum.filter(&(dest == "" or &1["destino"] == dest))
      |> Enum.sort_by(&{&1["inserted_at"], &1["id"]}, :desc)

    socket
    |> assign(:bitacora_vacia, registros == [])
    |> stream(:bitacora, registros, reset: true)
  end

  defp fecha(nil), do: ""
  defp fecha(texto), do: texto |> String.replace("T", " ") |> String.slice(0, 16)

  ## Render

  def render(assigns) do
    assigns = assign(assigns, :etiquetas_tipo, @etiquetas_tipo)

    ~H"""
    <div class="p-4 sm:p-6">
      <div class="flex items-center gap-2 mb-4">
        <.link
          navigate={~p"/"}
          title="Volver al inicio"
          class="w-7 h-7 flex items-center justify-center rounded-lg text-gray-500 hover:bg-gray-100 hover:text-gray-700 transition-colors shrink-0"
        >
          <span class="material-symbols-outlined" style="font-size: 18px">arrow_back</span>
        </.link>
        <div class="min-w-0">
          <h1 class="text-2xl font-bold">Purgar</h1>
          <p class="text-xs text-gray-400">
            Retira artefactos de los builds futuros y púrgalos ambiente por ambiente, como si nunca hubieran existido.
          </p>
        </div>
      </div>

      <div class="flex flex-wrap items-center gap-3 mb-4">
        <form id="purgar-ambiente" phx-change="elegir_ambiente">
          <select name="ambiente_id" class="border border-gray-300 rounded-lg px-2 py-1.5 text-sm">
            <option value="" selected={is_nil(@ambiente)}>Elige un ambiente...</option>
            <option :for={a <- @ambientes} value={a.id} selected={@ambiente && @ambiente.id == a.id}>
              {a.nombre} ({a.host})
            </option>
          </select>
        </form>
        <button
          :if={@ambiente}
          id="purgar-actualizar"
          type="button"
          phx-click="actualizar"
          class="flex items-center gap-1 px-3 py-1.5 rounded-lg border border-gray-300 text-sm text-gray-700 hover:bg-gray-50 transition-colors"
        >
          <span class="material-symbols-outlined" style="font-size: 16px">refresh</span> Actualizar
        </button>
      </div>

      <nav
        id="purgar-pestanas"
        class="flex gap-1 border-b border-gray-200 mb-5"
        aria-label="Pestañas"
      >
        <.link
          :for={{id, etiqueta, icono} <- @pestanas}
          id={"tab-#{id}"}
          patch={~p"/sysadmin/purgar?#{[pestana: id]}"}
          aria-current={if(@pestana == id, do: "page", else: "false")}
          class={[
            "flex items-center gap-1.5 px-3 py-2 -mb-px text-sm font-medium border-b-2 transition-colors",
            if(@pestana == id,
              do: "border-purple-600 text-purple-700",
              else: "border-transparent text-gray-500 hover:text-gray-700 hover:border-gray-300"
            )
          ]}
        >
          <span class="material-symbols-outlined" style="font-size: 18px">{icono}</span>
          {etiqueta}
        </.link>
      </nav>

      <section :if={@pestana == "artefactos"} id="purgar-artefactos">
        <p :if={is_nil(@ambiente)} class="text-sm text-gray-400">
          Elige un ambiente para consultar sus sistemas.
        </p>
        <p :if={@error_artefactos} class="text-sm text-red-600 mb-3">
          No se pudieron leer los releases de GitHub: {@error_artefactos}
        </p>
        <p
          :if={@ambiente && is_nil(@artefactos) && is_nil(@error_artefactos)}
          class="text-sm text-gray-400 animate-pulse"
        >
          Leyendo releases de GitHub…
        </p>

        <div :if={@artefactos} class="overflow-x-auto rounded-xl border border-gray-200">
          <table id="purgar-tabla" class="min-w-full text-sm">
            <thead class="bg-gray-50 text-xs text-gray-500">
              <tr>
                <th class="text-left font-semibold px-3 py-2 sticky left-0 bg-gray-50">Artefacto</th>
                <th :for={d <- @destinos} class="text-left font-semibold px-3 py-2 whitespace-nowrap">
                  {d}<span :if={d in @clientes} class="ml-1 text-[10px] text-gray-400">cliente</span>
                </th>
              </tr>
            </thead>
            <tbody class="divide-y divide-gray-100">
              <tr :if={filas(@artefactos, @presencia) == []}>
                <td colspan={length(@destinos) + 1} class="px-3 py-6 text-center text-gray-400">
                  No hay artefactos publicados ni retirados.
                </td>
              </tr>
              <tr
                :for={a <- filas(@artefactos, @presencia)}
                id={"art-#{a.nombre}"}
                class="hover:bg-gray-50/60 transition-colors"
              >
                <td class="px-3 py-2 align-top sticky left-0 bg-[var(--pc-bg-primario)]">
                  <div class="font-mono text-xs text-gray-900">{a.nombre}</div>
                  <div class="flex flex-wrap items-center gap-1 mt-1">
                    <span class="text-[10px] px-1.5 py-0.5 rounded bg-slate-100 text-slate-600">
                      {@etiquetas_tipo[a.tipo] || a.tipo}
                    </span>
                    <span class={["text-[10px] px-1.5 py-0.5 rounded", elem(estado_fila(a), 1)]}>
                      {elem(estado_fila(a), 0)}
                    </span>
                  </div>
                  <p :if={@en_curso[a.nombre]} class="text-[11px] text-purple-700 mt-1 animate-pulse">
                    {@en_curso[a.nombre]}
                  </p>
                  <div class="flex flex-wrap gap-2 mt-1.5">
                    <button
                      :if={a.paquetes != [] and is_nil(@en_curso[a.nombre])}
                      id={"retirar-#{a.nombre}"}
                      type="button"
                      phx-click="abrir_retiro"
                      phx-value-nombre={a.nombre}
                      class="text-xs text-amber-700 hover:text-amber-900 hover:underline"
                    >
                      Retirar
                    </button>
                    <button
                      :if={puede_borrar_inventario?(a, @presencia)}
                      id={"borrar-inventario-#{a.nombre}"}
                      type="button"
                      phx-click="abrir_borrar_inventario"
                      phx-value-nombre={a.nombre}
                      class="text-xs text-gray-500 hover:text-red-700 hover:underline"
                    >
                      Borrar inventario
                    </button>
                  </div>
                </td>
                <td :for={d <- @destinos} class="px-3 py-2 align-top whitespace-nowrap">
                  <%= case celda(a, @presencia[d]) do %>
                    <% :cargando -> %>
                      <span class="text-gray-300 animate-pulse">…</span>
                    <% :sin_purga -> %>
                      <span
                        class="text-[11px] text-amber-600"
                        title="Ese sistema corre una versión anterior a la purga"
                      >
                        sin purga
                      </span>
                    <% {:error, motivo} -> %>
                      <span class="text-[11px] text-red-600" title={motivo_legible(motivo)}>
                        error
                      </span>
                    <% :ausente -> %>
                      <span class="text-gray-300">—</span>
                    <% {:presente, filas} -> %>
                      <div class="flex items-center gap-2">
                        <span class="inline-flex items-center gap-1 text-xs text-gray-700">
                          <span class="w-1.5 h-1.5 rounded-full bg-emerald-500"></span>
                          {if filas, do: "~#{filas} reg.", else: "presente"}
                        </span>
                        <button
                          :if={
                            (a.retirado or (d == "unstable" and a.paquetes != [])) and
                              not a.solo_en_destino and is_nil(@en_curso[a.nombre])
                          }
                          id={"purgar-#{a.nombre}-#{d}"}
                          type="button"
                          phx-click="abrir_purga"
                          phx-value-nombre={a.nombre}
                          phx-value-destino={d}
                          class="text-xs px-2 py-0.5 rounded-md bg-red-50 text-red-700 hover:bg-red-100 transition-colors"
                        >
                          {if a.retirado, do: "Purgar", else: "Retirar y purgar"}
                        </button>
                      </div>
                  <% end %>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>

      <section :if={@pestana == "bitacora"} id="purgar-bitacora">
        <p :if={is_nil(@ambiente)} class="text-sm text-gray-400 mb-3">
          Elige un ambiente para consultar sus sistemas.
        </p>
        <form id="bitacora-filtro" phx-change="filtrar_bitacora" class="flex flex-wrap gap-2 mb-3">
          <input
            type="text"
            name="filtro[artefacto]"
            value={@filtro["artefacto"]}
            placeholder="Artefacto…"
            phx-debounce="300"
            class="border border-gray-300 rounded-lg px-2 py-1.5 text-sm w-48"
          />
          <select name="filtro[destino]" class="border border-gray-300 rounded-lg px-2 py-1.5 text-sm">
            <option value="">Todos los destinos</option>
            <option :for={d <- @destinos} value={d} selected={@filtro["destino"] == d}>{d}</option>
          </select>
        </form>

        <p :for={{d, motivo} <- @bitacora_errores} class="text-xs text-amber-700 mb-1">
          {d}: {motivo_legible(motivo)}
        </p>

        <div class="overflow-x-auto rounded-xl border border-gray-200">
          <table class="min-w-full text-sm">
            <thead class="bg-gray-50 text-xs text-gray-500">
              <tr>
                <th class="text-left font-semibold px-3 py-2">Fecha (UTC)</th>
                <th class="text-left font-semibold px-3 py-2">Destino</th>
                <th class="text-left font-semibold px-3 py-2">Artefacto</th>
                <th class="text-left font-semibold px-3 py-2">Acción</th>
                <th class="text-left font-semibold px-3 py-2">Resultado</th>
                <th class="text-left font-semibold px-3 py-2">Usuario</th>
                <th class="text-left font-semibold px-3 py-2">Detalle</th>
              </tr>
            </thead>
            <tbody id="bitacora-registros" phx-update="stream" class="divide-y divide-gray-100">
              <tr id="bitacora-vacia" class="hidden only:table-row">
                <td colspan="7" class="px-3 py-6 text-center text-gray-400">Sin registros.</td>
              </tr>
              <tr :for={{id, r} <- @streams.bitacora} id={id}>
                <td class="px-3 py-2 whitespace-nowrap text-xs text-gray-500">
                  {fecha(r["inserted_at"])}
                </td>
                <td class="px-3 py-2 text-xs">{r["destino"]}</td>
                <td class="px-3 py-2 font-mono text-xs">{r["artefacto"]}</td>
                <td class="px-3 py-2 text-xs">{r["accion"]}</td>
                <td class="px-3 py-2">
                  <span class={[
                    "text-[11px] px-1.5 py-0.5 rounded",
                    case r["resultado"] do
                      "ok" -> "bg-emerald-50 text-emerald-700"
                      "error" -> "bg-red-50 text-red-700"
                      _ -> "bg-slate-100 text-slate-600"
                    end
                  ]}>
                    {r["resultado"]}
                  </span>
                </td>
                <td class="px-3 py-2 text-xs text-gray-600">{r["usuario_email"]}</td>
                <td class="px-3 py-2 text-xs text-gray-600 max-w-md">
                  <div :if={r["mensaje"]}>{r["mensaje"]}</div>
                  <div :if={r["respaldo"]} class="font-mono text-[11px] text-gray-500">
                    Respaldo: {r["respaldo"]}
                  </div>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>

      <div
        :if={@modal}
        id="modal-purga"
        class="fixed inset-0 bg-black/40 flex items-center justify-center z-50 p-4"
        phx-window-keydown="cerrar_modal"
        phx-key="escape"
      >
        <div class="bg-white text-gray-900 rounded-xl shadow-lg max-w-lg w-full p-6 max-h-[90vh] overflow-y-auto">
          <h2 class="text-lg font-bold mb-1">
            <%= case @modal.tipo do %>
              <% :retirar -> %>
                Retirar {@modal.nombre}
              <% :borrar_inventario -> %>
                Borrar inventario de {@modal.nombre}
              <% :purgar -> %>
                {if @modal.un_paso, do: "Retirar y purgar", else: "Purgar"} {@modal.nombre} en {@modal.destino}
            <% end %>
          </h2>

          <div class="text-sm text-gray-600 space-y-2 mb-4">
            <%= case @modal.tipo do %>
              <% :retirar -> %>
                <p>
                  Deja de incluirse en cualquier build futuro. Sus archivos se sacan de todos los paquetes que lo traen y se guardan como inventario en <span class="font-mono">retirado-{@modal.nombre}</span>.
                </p>
                <p>No borra nada en ningún ambiente: después hay que purgarlo en cada uno.</p>
              <% :borrar_inventario -> %>
                <p>
                  Ya no existe en ningún destino. Se borra
                  <span class="font-mono">retirado-{@modal.nombre}</span>
                  para siempre.
                </p>
              <% :purgar -> %>
                <p :if={@modal.cargando} class="animate-pulse text-gray-400">
                  Consultando {@modal.destino}…
                </p>
                <%= if @modal.prep do %>
                  <p :if={@modal.un_paso}>
                    Se retira, se reconstruye unstable y, cuando la imagen nueva esté arriba, se purga solo. Puede tardar varios minutos.
                  </p>
                  <p :if={@modal.prep.cliente}>
                    Es un cliente: antes de borrar se guarda un respaldo de sus tablas en su servidor (30 días).
                  </p>
                  <ul class="rounded-lg border border-gray-200 divide-y divide-gray-100">
                    <li
                      :for={t <- @modal.prep.impacto["tablas"] || []}
                      class="flex justify-between px-3 py-1.5 text-xs"
                    >
                      <span class="font-mono">{t["nombre"]}</span>
                      <span class="text-gray-500">
                        {t["objeto"] || "sin objeto"} · {t["filas"]} reg.
                      </span>
                    </li>
                  </ul>
                  <p class="text-xs text-gray-500">
                    Migraciones a limpiar: {length(@modal.prep.impacto["versiones_aplicadas"] || [])}
                  </p>
                  <div
                    :if={bloqueo_modal(@modal)}
                    class="rounded-lg bg-red-50 text-red-700 text-xs p-3"
                  >
                    {bloqueo_modal(@modal)}
                  </div>
                <% end %>
            <% end %>
          </div>

          <form
            :if={@modal.tipo != :purgar or (@modal.prep && is_nil(bloqueo_modal(@modal)))}
            id="form-confirmacion"
            phx-change="validar_confirmacion"
            phx-submit="confirmar"
          >
            <label class="text-xs font-semibold text-gray-500">
              Escribe <span class="font-mono text-gray-800">{@modal.nombre}</span> para confirmar
            </label>
            <input
              id="purga-confirmar-nombre"
              type="text"
              name="confirmacion[nombre]"
              value={@modal.escrito}
              autocomplete="off"
              phx-debounce="100"
              class="w-full border border-gray-300 rounded-lg px-3 py-2 text-sm font-mono text-gray-900 bg-white mt-1 mb-3"
            />
            <label
              :if={filas_modal(@modal) > 0}
              class="flex items-start gap-2 text-sm text-red-700 mb-3"
            >
              <input type="hidden" name="confirmacion[acepto_filas]" value="false" />
              <input
                id="purga-acepto-filas"
                type="checkbox"
                name="confirmacion[acepto_filas]"
                value="true"
                checked={@modal.acepto_filas}
                class="mt-0.5"
              /> Entiendo que se borran {filas_modal(@modal)} registro(s).
            </label>
            <label
              :if={@modal.tipo == :purgar and @modal.copia_local}
              class="flex items-start gap-2 text-sm text-gray-700 mb-3"
            >
              <input type="hidden" name="confirmacion[limpiar_local]" value="false" />
              <input
                id="purga-limpiar-local"
                type="checkbox"
                name="confirmacion[limpiar_local]"
                value="true"
                checked={@modal.limpiar_local}
                class="mt-0.5"
              />
              <span>
                Borrar también mi copia local (base, archivos y migraciones), sin dejar migración de borrado.
                <span class="block text-xs text-gray-500">
                  Las copias de los demás desarrolladores no se tocan.
                </span>
              </span>
            </label>
            <p :if={@modal.error} class="text-xs text-red-600 mb-3">{@modal.error}</p>
            <div class="flex justify-end gap-2">
              <button
                type="button"
                phx-click="cerrar_modal"
                class="px-4 py-2 rounded border border-gray-300 text-gray-700 text-sm font-semibold hover:bg-gray-50"
              >
                Cancelar
              </button>
              <button
                id="purga-confirmar"
                type="submit"
                disabled={not puede_confirmar?(@modal)}
                class="px-4 py-2 rounded bg-red-600 text-white text-sm font-semibold hover:bg-red-700 disabled:opacity-40 disabled:cursor-not-allowed transition-colors"
              >
                {if @modal.ejecutando, do: "Trabajando…", else: "Confirmar"}
              </button>
            </div>
          </form>

          <div
            :if={@modal.tipo == :purgar and (is_nil(@modal.prep) or bloqueo_modal(@modal))}
            class="flex flex-col gap-2 items-end"
          >
            <p :if={@modal.error} class="text-xs text-red-600 self-start">{@modal.error}</p>
            <button
              type="button"
              phx-click="cerrar_modal"
              class="px-4 py-2 rounded border border-gray-300 text-gray-700 text-sm font-semibold hover:bg-gray-50"
            >
              Cerrar
            </button>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
