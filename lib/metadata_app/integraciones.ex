defmodule MetadataApp.Integraciones do
  @moduledoc """
  Contexto de "Integraciones" (2026-08-07) — credenciales de sistemas
  externos + las acciones (llamadas HTTP configurables) que las usan. A
  propósito NO es parte del sistema genérico de catálogos/BC — es su
  propio modelo, chico y auditable, precisamente para no tener que hacer
  que TODO el camino genérico (tabla, formulario, GET, filtros, orden,
  PostView) sepa nunca mostrar/filtrar/ordenar un campo cifrado (ver
  conversación 2026-08-06, decisión explícita de arquitectura).
  """

  import Ecto.Query
  require Logger
  alias MetadataApp.Repo
  alias MetadataApp.Integraciones.{Credencial, AccionExterna, AccionLog}
  alias MetadataApp.BusinessProcessBuilder.MetaSchemaContext
  alias MetadataApp.Permissions

  ## Credenciales

  @doc "Todas las credenciales vivas, orden alfabético por nombre."
  def listar_credenciales do
    from(c in Credencial, where: is_nil(c.delete_guid), order_by: c.nombre)
    |> Repo.all()
  end

  def obtener_credencial!(id) do
    from(c in Credencial, where: c.id == ^id and is_nil(c.delete_guid))
    |> Repo.one!()
  end

  def crear_credencial(attrs) do
    %Credencial{}
    |> Credencial.changeset_creacion(attrs)
    |> Ecto.Changeset.change(%{insert_guid: generar_guid()})
    |> Repo.insert()
  end

  def actualizar_credencial(%Credencial{} = credencial, attrs) do
    credencial
    |> Credencial.changeset_edicion(attrs)
    |> Ecto.Changeset.change(%{update_guid: generar_guid()})
    |> Repo.update()
  end

  @doc "Soft-delete, mismo criterio que el resto del sistema."
  def eliminar_credencial(%Credencial{} = credencial) do
    credencial
    |> Ecto.Changeset.change(%{delete_guid: generar_guid()})
    |> Repo.update()
  end

  @doc """
  Registra el resultado de la última ejecución contra esta credencial
  (ultimo_error: nil si salió bien) -- usado por Integraciones.ejecutar/2
  (Fase 4) para que la pantalla de Credenciales pueda mostrar "esto lleva
  fallando desde tal fecha" sin que nadie tenga que revisar las 50 a
  mano. No pasa por Credencial.changeset_edicion/2 a propósito -- eso
  exigiría api_key_nuevo/nombre, que acá no vienen ni deben tocarse.
  """
  def registrar_resultado_ejecucion(%Credencial{} = credencial, error_o_nil) do
    credencial
    |> Ecto.Changeset.change(%{ultima_ejecucion_en: DateTime.utc_now(:second), ultimo_error: error_o_nil})
    |> Repo.update()
  end

  ## Acciones externas

  @doc "Todas las acciones vivas de un catálogo/consulta puntual, en orden."
  def listar_acciones(header_id) do
    from(a in AccionExterna,
      where: a.meta_schema_header_id == ^header_id and is_nil(a.delete_guid),
      order_by: a.orden,
      preload: [:credencial]
    )
    |> Repo.all()
  end

  @doc "Todas las acciones vivas de cualquier catálogo (o standalone), para el panel de administración (AccionesExternasLive)."
  def listar_todas_acciones do
    from(a in AccionExterna, where: is_nil(a.delete_guid), order_by: a.nombre, preload: [:credencial, :header])
    |> Repo.all()
  end

  @doc "Todas las acciones standalone (sin catálogo asociado) + las de cualquier catálogo, para el panel de Credenciales (ver qué usa cada una)."
  def listar_acciones_de_credencial(credencial_id) do
    from(a in AccionExterna, where: a.credencial_id == ^credencial_id and is_nil(a.delete_guid), order_by: a.nombre)
    |> Repo.all()
  end

  def obtener_accion!(id) do
    from(a in AccionExterna, where: a.id == ^id and is_nil(a.delete_guid), preload: [:credencial, :header])
    |> Repo.one!()
  end

  def crear_accion(attrs) do
    %AccionExterna{}
    |> AccionExterna.changeset(attrs)
    |> Ecto.Changeset.change(%{insert_guid: generar_guid()})
    |> Repo.insert()
    |> registrar_permiso_ejecucion()
  end

  def actualizar_accion(%AccionExterna{} = accion, attrs) do
    accion
    |> AccionExterna.changeset(attrs)
    |> Ecto.Changeset.change(%{update_guid: generar_guid()})
    |> Repo.update()
    |> registrar_permiso_ejecucion()
  end

  # RBAC (Fase 7 de "Integraciones", 2026-08-07) — sin un Permiso
  # {recurso: catálogo, accion: "ejecutar_<nombre>"} YA REGISTRADO, NADIE
  # puede ejecutar el botón desde la Ficha 360° (ver
  # FichaLive.cargar_registro/2), ni siquiera un "administrador" —
  # can?/3 exige que la fila exista, ser administrador solo salta la
  # concesión por rol, no la existencia del permiso (ver
  # Permissions.cargar_permisos_de_db/2). Automático acá, a diferencia de
  # las transiciones (que exigen un click aparte en BcMotorLive,
  # "registrar_permiso_transicion") -- exactamente ESE paso manual fue un
  # bug real en producción una vez (permiso olvidado, acción invisible
  # para todos); en una acción externa recién creada no hay ninguna razón
  # para repetir ese riesgo. Solo aplica si la acción está atada a un
  # catálogo -- una standalone (solo para reglas post, sin botón en
  # ninguna ficha) no necesita permiso de "ejecutar" de un usuario.
  defp registrar_permiso_ejecucion({:ok, %AccionExterna{meta_schema_header_id: nil} = accion}), do: {:ok, accion}

  defp registrar_permiso_ejecucion({:ok, %AccionExterna{meta_schema_header_id: header_id, nombre: nombre} = accion}) do
    header = MetaSchemaContext.obtener_header!(header_id)
    Permissions.crear_permiso(%{recurso: header.schema_context_name, accion: "ejecutar_#{nombre}"})
    {:ok, accion}
  end

  defp registrar_permiso_ejecucion({:error, _changeset} = error), do: error

  def eliminar_accion(%AccionExterna{} = accion) do
    accion
    |> Ecto.Changeset.change(%{delete_guid: generar_guid()})
    |> Repo.update()
  end

  ## Motor de ejecución (Fase 4, 2026-08-07)

  @timeout_default_ms 15_000

  @doc """
  Resuelve la acción por nombre DENTRO del catálogo de `registro` (mismo
  criterio que MetaStateEngine.Reglas.catalogo_de/1: el nombre de tabla
  del schema del registro) y la ejecuta. Pensado para el caso más común,
  llamado desde una regla post:

      MetadataApp.Integraciones.ejecutar("validar_credito", registro)

  Para el caso "regla post síncrona, dentro de la transacción" (ver
  conversación 2026-08-06), pasar `timeout: 5_000..8_000` explícito en
  `opts` -- el default (15s) es para el botón interactivo async (Fase 6),
  demasiado largo para tener abierta una conexión de Postgres del pool.
  """
  def ejecutar(nombre_accion, registro, opts \\ []) when is_binary(nombre_accion) do
    catalogo = registro.__struct__.__schema__(:source)

    case MetadataApp.BusinessProcessBuilder.MetaSchemaContext.obtener_header_por_nombre(catalogo) do
      nil ->
        {:error, {:accion_no_encontrada, "catálogo \"#{catalogo}\" no existe"}}

      header ->
        query =
          from(a in AccionExterna,
            where: a.meta_schema_header_id == ^header.id and a.nombre == ^nombre_accion and is_nil(a.delete_guid),
            preload: [:credencial]
          )

        case Repo.one(query) do
          nil -> {:error, {:accion_no_encontrada, nombre_accion}}
          accion -> ejecutar_accion(accion, registro, opts)
        end
    end
  end

  @doc "Igual que ejecutar/3 pero con la %AccionExterna{} ya resuelta (ver Fase 6, botón interactivo, que ya la tiene a mano)."
  def ejecutar_accion(%AccionExterna{} = accion, registro, opts \\ []) do
    # Siempre fresca de DB (nunca confiar en un preload que puede o no
    # venir cargado según cómo el caller haya resuelto `accion`) -- el
    # costo de una consulta más es insignificante al lado de la llamada
    # de red que sigue.
    credencial = obtener_credencial!(accion.credencial_id)
    sustituir = &MetadataApp.BusinessProcessBuilder.CatalogoGenerico.sustituir_variables/2

    url =
      accion.url_template
      |> sustituir.(registro)
      |> String.replace("{api_key}", credencial.api_key)
      |> String.replace("{base_url}", credencial.base_url || "")

    headers =
      Map.new(accion.headers_template || %{}, fn {clave, valor} ->
        valor_resuelto =
          valor
          |> to_string()
          |> sustituir.(registro)
          |> String.replace("{api_key}", credencial.api_key)

        {clave, valor_resuelto}
      end)

    body =
      case accion.body_template do
        nil -> nil
        plantilla -> plantilla |> sustituir.(registro) |> String.replace("{api_key}", credencial.api_key)
      end

    timeout = Keyword.get(opts, :timeout, @timeout_default_ms)
    metodo = accion.metodo |> String.downcase() |> String.to_existing_atom()
    inicio = System.monotonic_time(:millisecond)

    resultado =
      try do
        req_opts =
          [
            method: metodo,
            url: url,
            headers: headers,
            receive_timeout: timeout,
            connect_options: [timeout: timeout],
            # Req reintenta 5xx solo por default (encontrado real: 3
            # reintentos con backoff 1s/2s/4s, ~7s extra) -- eso hace que
            # cualquier `timeout` de acá arriba no sirva de nada. Sin
            # reintentos automáticos a propósito (ver conversación
            # 2026-08-06): si falla, que falle rápido y sea el caller
            # quien decida si reintentar todo el guardado/acción.
            retry: false
          ]
          |> then(fn o -> if body, do: Keyword.put(o, :body, body), else: o end)

        case Req.request(req_opts) do
          {:ok, %Req.Response{status: status, body: resp_body}} -> {:ok, %{status: status, body: resp_body}}
          {:error, %{reason: :timeout}} -> {:error, :timeout}
          {:error, motivo} -> {:error, {:conexion, motivo}}
        end
      rescue
        e -> {:error, {:excepcion, Exception.message(e)}}
      end

    error_para_registrar =
      case resultado do
        {:ok, %{status: status}} when status in 200..299 -> nil
        {:ok, %{status: status}} -> "HTTP #{status}"
        {:error, motivo} -> inspect(motivo)
      end

    registrar_resultado_ejecucion(credencial, error_para_registrar)
    registrar_log(accion, registro, resultado, System.monotonic_time(:millisecond) - inicio, opts)

    resultado
  end

  # Fase 8 ("Integraciones") -- best-effort a propósito (rescue, nunca
  # tumba la llamada real por un problema de logging): a diferencia de
  # registrar_resultado_ejecucion/2 (un solo UPDATE, "estado actual" de la
  # credencial), esto es un INSERT append-only, pensado para responder
  # "¿esta acción de verdad corrió cuando alguien la clickeó?" (ver
  # AccionesExternasLive, panel "Últimas ejecuciones", y el badge de
  # CredencialesLive). `origen`/`usuario_id` en `opts` -- FichaLive pasa
  # origen: "usuario" + el id de quien clickeó; una regla post (Fase 5) no
  # pasa nada y cae al default "regla_post" (ver moduledoc de ejecutar/2:
  # ese es el caso pensado de entrada). Corre con el mismo Repo que el
  # resto de la función -- si esto se llama DENTRO de la transacción de una
  # regla post (Fase 5) y esa transacción termina revirtiendo, esta fila se
  # revierte con ella (mismo límite ya aceptado en Fase 4 para
  # registrar_resultado_ejecucion/2 -- separarlo de la transacción exigiría
  # una conexión/proceso aparte, fuera de alcance acá).
  defp registrar_log(accion, registro, resultado, duracion_ms, opts) do
    {ok?, status, error} =
      case resultado do
        {:ok, %{status: status}} -> {status in 200..299, status, nil}
        {:error, motivo} -> {false, nil, inspect(motivo)}
      end

    %AccionLog{}
    |> Ecto.Changeset.change(%{
      accion_id: accion.id,
      credencial_id: accion.credencial_id,
      usuario_id: Keyword.get(opts, :usuario_id),
      accion_nombre: accion.nombre,
      catalogo: registro.__struct__.__schema__(:source),
      registro_id: registro.id,
      origen: Keyword.get(opts, :origen, "regla_post"),
      ok: ok?,
      status_http: status,
      error: error,
      duracion_ms: duracion_ms
    })
    |> Repo.insert()
  rescue
    e -> Logger.warning("No se pudo escribir el log de ejecución de \"#{accion.nombre}\": #{Exception.message(e)}")
  end

  ## Observabilidad (Fase 8)

  @doc "Últimas ejecuciones de UNA acción puntual, más recientes primero -- panel \"Últimas ejecuciones\" de AccionesExternasLive."
  def listar_log(accion_id, limite \\ 20) do
    from(l in AccionLog, where: l.accion_id == ^accion_id, order_by: [desc: l.id], limit: ^limite, preload: [:usuario])
    |> Repo.all()
  end

  @doc """
  Resumen de TODAS las acciones de una credencial en los últimos `dias`
  (default 7) -- el badge de CredencialesLive ("¿esta credencial anda
  fallando?"), sin tener que abrir cada acción una por una.
  """
  def resumen_ejecuciones(credencial_id, dias \\ 7) do
    desde = DateTime.add(DateTime.utc_now(), -dias, :day)

    from(l in AccionLog,
      where: l.credencial_id == ^credencial_id and l.inserted_at >= ^desde,
      select: %{total: count(l.id), errores: filter(count(l.id), l.ok == false)}
    )
    |> Repo.one()
  end

  defp generar_guid do
    Ecto.UUID.generate() |> String.replace("-", "")
  end
end
