defmodule MetadataApp.Permissions do
  @moduledoc """
  Autorización centralizada (RBAC). Ninguna vista, controller o channel
  evalúa permisos por su cuenta — todo pasa por `can?/3`.

  Los permisos efectivos de un `{usuario_id, empresa_id}` se cachean en ETS
  (`MetadataApp.Permissions.Cache`) con un TTL corto — se recalculan solos
  al vencer, y se invalidan explícitamente al asignar/revocar un rol.
  """

  import Ecto.Query

  alias MetadataApp.Repo
  alias MetadataApp.Autenticacion.{Scope, Rol, RolPermiso, Permiso, UsuarioRol, Usuario, UsuarioEmpresa}
  alias MetadataApp.BusinessProcessBuilder.MetaSchema.Header
  alias MetadataApp.Permissions.Cache

  @ttl_ms :timer.minutes(5)
  @acciones ~w(leer crear editar eliminar)

  @doc """
  Extrae de un Scope real (sesión de navegador ya autenticada) los ids que
  el motor de estados puede confiar para `requiere_permiso` — se mergean
  DESPUÉS de cualquier contexto que venga del cliente, para que ningún
  `usuario_id`/`empresa_id` mandado en un body JSON pueda pisarlos.
  """
  def contexto_confiable(%Scope{usuario: usuario, empresa_activa: empresa}) do
    %{"usuario_id" => usuario && usuario.id, "empresa_id" => empresa && empresa.id}
  end

  def contexto_confiable(nil), do: %{"usuario_id" => nil, "empresa_id" => nil}

  @doc "Resuelve siempre contra scope.empresa_activa — nunca contra un empresa_id de parámetro del cliente."
  def can?(%Scope{usuario: nil}, _accion, _recurso), do: false
  def can?(%Scope{empresa_activa: nil}, _accion, _recurso), do: false

  def can?(%Scope{usuario: usuario, empresa_activa: empresa}, accion, recurso) do
    usuario.id
    |> permisos_de_usuario(empresa.id)
    |> Enum.any?(&(&1.recurso == recurso and &1.accion == accion))
  end

  @doc "Lista efectiva de permisos de un usuario en una empresa (unión de sus roles), cacheada."
  def permisos_de_usuario(usuario_id, empresa_id) do
    chave = {usuario_id, empresa_id}
    agora = System.monotonic_time(:millisecond)

    case :ets.lookup(Cache.tabla(), chave) do
      [{^chave, permisos, expira_en}] when expira_en > agora -> permisos
      _ -> cargar_y_cachear(chave, usuario_id, empresa_id)
    end
  end

  defp cargar_y_cachear(chave, usuario_id, empresa_id) do
    permisos = cargar_permisos_de_db(usuario_id, empresa_id)
    expira_en = System.monotonic_time(:millisecond) + @ttl_ms
    :ets.insert(Cache.tabla(), {chave, permisos, expira_en})
    permisos
  end

  # "administrador" no depende de tener cada permiso linkeado a mano en
  # meta_schema_rol_permiso — se reconoce por es_sistema + nombre y pasa
  # siempre, contra el catálogo completo de permisos vivos.
  defp cargar_permisos_de_db(usuario_id, empresa_id) do
    if administrador?(usuario_id, empresa_id) do
      Repo.all(from p in Permiso, where: is_nil(p.delete_guid))
    else
      from(p in Permiso,
        join: rp in RolPermiso, on: rp.permiso_id == p.id and is_nil(rp.delete_guid),
        join: r in Rol, on: r.id == rp.rol_id and is_nil(r.delete_guid),
        join: ur in UsuarioRol,
        on:
          ur.rol_id == r.id and is_nil(ur.delete_guid) and
            (r.empresa_id == ^empresa_id or is_nil(r.empresa_id)),
        where: ur.usuario_id == ^usuario_id and ur.empresa_id == ^empresa_id and is_nil(p.delete_guid),
        distinct: true
      )
      |> Repo.all()
    end
  end

  defp administrador?(usuario_id, empresa_id) do
    Repo.exists?(
      from ur in UsuarioRol,
        join: r in Rol,
        on: r.id == ur.rol_id and is_nil(r.delete_guid),
        where:
          ur.usuario_id == ^usuario_id and ur.empresa_id == ^empresa_id and is_nil(ur.delete_guid) and
            r.es_sistema == true and r.nombre == "administrador"
    )
  end

  @doc "Borra la entrada de cache de un usuario/empresa — se recalcula sola en el próximo can?/3."
  def invalidar_cache(usuario_id, empresa_id) do
    :ets.delete(Cache.tabla(), {usuario_id, empresa_id})
    :ok
  end

  ## Administración de roles y permisos

  def crear_permiso(attrs) do
    resultado =
      %Permiso{}
      |> Permiso.changeset(attrs)
      |> Ecto.Changeset.change(%{insert_guid: generar_guid()})
      |> Repo.insert()

    # Un administrador ve TODO permiso vivo sin depender de una concesión
    # por rol (cargar_permisos_de_db/2, bypass total) — así que su caché
    # queda stale apenas aparece un permiso nuevo, sin que ninguna
    # concesión a otro rol lo toque. Bug real: un catálogo recién creado
    # (sin permisos concedidos todavía a NINGÚN rol del administrador)
    # quedaba invisible en el menú hasta que el TTL de 5 min expiraba solo.
    case resultado do
      {:ok, _permiso} -> invalidar_cache_de_administradores()
      _error -> :ok
    end

    resultado
  end

  defp invalidar_cache_de_administradores do
    from(ur in UsuarioRol,
      join: r in Rol, on: r.id == ur.rol_id and is_nil(r.delete_guid),
      where: is_nil(ur.delete_guid) and r.es_sistema == true and r.nombre == "administrador",
      select: {ur.usuario_id, ur.empresa_id}
    )
    |> Repo.all()
    |> Enum.each(fn {usuario_id, empresa_id} -> invalidar_cache(usuario_id, empresa_id) end)
  end

  def crear_rol(attrs) do
    %Rol{}
    |> Rol.changeset(attrs)
    |> Ecto.Changeset.change(%{insert_guid: generar_guid()})
    |> Repo.insert()
  end

  def asignar_permiso_a_rol(rol_id, permiso_id) do
    %RolPermiso{}
    |> RolPermiso.changeset(%{rol_id: rol_id, permiso_id: permiso_id})
    |> Ecto.Changeset.change(%{insert_guid: generar_guid()})
    |> Repo.insert()
  end

  @doc """
  Asigna un rol a un usuario dentro de una empresa. Si el rol no es de
  sistema (tiene `empresa_id` propio), tiene que coincidir con la empresa
  que se le está asignando — no se puede prestar un rol de otra empresa.
  """
  def asignar_rol(usuario_id, rol_id, empresa_id) do
    with :ok <- validar_rol_de_la_empresa(rol_id, empresa_id) do
      resultado =
        %UsuarioRol{}
        |> UsuarioRol.changeset(%{usuario_id: usuario_id, rol_id: rol_id, empresa_id: empresa_id})
        |> Ecto.Changeset.change(%{insert_guid: generar_guid()})
        |> Repo.insert()

      invalidar_cache(usuario_id, empresa_id)
      resultado
    end
  end

  @doc "Revoca (soft-delete) la asignación de un rol a un usuario en una empresa."
  def revocar_rol(usuario_id, rol_id, empresa_id) do
    query =
      from ur in UsuarioRol,
        where:
          ur.usuario_id == ^usuario_id and ur.rol_id == ^rol_id and ur.empresa_id == ^empresa_id and
            is_nil(ur.delete_guid)

    resultado =
      case Repo.one(query) do
        nil ->
          {:error, :no_encontrado}

        usuario_rol ->
          usuario_rol
          |> Ecto.Changeset.change(%{delete_guid: generar_guid()})
          |> Repo.update()
      end

    invalidar_cache(usuario_id, empresa_id)
    resultado
  end

  defp validar_rol_de_la_empresa(rol_id, empresa_id) do
    case Repo.get(Rol, rol_id) do
      nil -> {:error, :no_encontrado}
      %Rol{empresa_id: nil} -> :ok
      %Rol{empresa_id: ^empresa_id} -> :ok
      %Rol{} -> {:error, :rol_de_otra_empresa}
    end
  end

  @doc "Roles visibles para una empresa: los suyos propios + los de sistema (empresa_id nil)."
  def listar_roles(empresa_id) do
    Repo.all(
      from r in Rol,
        where: is_nil(r.delete_guid) and (r.empresa_id == ^empresa_id or is_nil(r.empresa_id))
    )
  end

  @doc """
  Búsqueda acotada de roles por nombre (empresa + sistema), mismo criterio
  de escala que buscar_catalogos/2 — pensado para empresas con cientos de
  roles, donde listar_roles/1 completo ya no es una lista razonable de
  mostrar entera en una UI (ej. selector de roles a agregar a un usuario).
  Sin texto, no devuelve nada (evita mostrar los primeros N sin que el
  admin haya pedido nada puntual).
  """
  def buscar_roles(empresa_id, query, limite \\ 20)

  def buscar_roles(_empresa_id, "", _limite), do: []

  def buscar_roles(empresa_id, query, limite) do
    texto = "%#{query}%"

    Repo.all(
      from r in Rol,
        where:
          is_nil(r.delete_guid) and (r.empresa_id == ^empresa_id or is_nil(r.empresa_id)) and
            ilike(r.nombre, ^texto),
        order_by: r.nombre,
        limit: ^limite
    )
  end

  def obtener_rol(id) do
    case Repo.get(Rol, id) do
      nil -> {:error, :no_encontrado}
      %Rol{delete_guid: nil} = rol -> {:ok, rol}
      %Rol{} -> {:error, :no_encontrado}
    end
  end

  @doc "Bloqueado si el rol es de sistema — hoy solo \"administrador\" (\"consulta\" se dio de baja, ver migración 20260803210418)."
  def actualizar_rol(%Rol{es_sistema: true}, _attrs), do: {:error, :rol_de_sistema}

  def actualizar_rol(rol, attrs) do
    rol
    |> Rol.changeset(attrs)
    |> Ecto.Changeset.change(%{update_guid: generar_guid()})
    |> Repo.update()
  end

  @doc "Soft-delete, bloqueado si el rol es de sistema."
  def eliminar_rol(%Rol{es_sistema: true}), do: {:error, :rol_de_sistema}

  def eliminar_rol(rol) do
    rol
    |> Ecto.Changeset.change(%{delete_guid: generar_guid()})
    |> Repo.update()
  end

  def listar_permisos do
    Repo.all(from p in Permiso, where: is_nil(p.delete_guid))
  end

  @doc "true si ya existe una fila de permiso para {recurso, accion} — usado para saber si una transición ya es discoverable/ejecutable por alguien (ver el aviso inline en BcMotorLive)."
  def permiso_existe?(recurso, accion) do
    Repo.exists?(from p in Permiso, where: p.recurso == ^recurso and p.accion == ^accion and is_nil(p.delete_guid))
  end

  @doc """
  Reemplazo atómico de los permisos de un rol (PUT, no PATCH incremental) —
  borra los vínculos actuales e inserta los nuevos en la misma transacción.
  Invalida el cache de TODOS los usuarios que tengan este rol asignado en
  cualquier empresa (no solo de quien hizo el cambio): cambiar qué puede
  hacer un rol afecta a todo el mundo que lo tenga, no a una sola sesión.
  """
  def reemplazar_permisos_de_rol(rol_id, permiso_ids) when is_binary(rol_id) do
    reemplazar_permisos_de_rol(String.to_integer(rol_id), permiso_ids)
  end

  def reemplazar_permisos_de_rol(rol_id, permiso_ids) do
    permiso_ids = Enum.map(permiso_ids, &normalizar_id/1)

    multi =
      Ecto.Multi.new()
      |> Ecto.Multi.delete_all(:borrar_actuales, from(rp in RolPermiso, where: rp.rol_id == ^rol_id))
      |> Ecto.Multi.insert_all(:insertar_nuevos, RolPermiso, fn _cambios ->
        Enum.map(permiso_ids, fn permiso_id ->
          %{rol_id: rol_id, permiso_id: permiso_id, insert_guid: generar_guid()}
        end)
      end)

    case Repo.transaction(multi) do
      {:ok, _} ->
        invalidar_cache_de_rol(rol_id)
        :ok

      {:error, _paso, razon, _cambios} ->
        {:error, razon}
    end
  end

  defp normalizar_id(id) when is_binary(id), do: String.to_integer(id)
  defp normalizar_id(id) when is_integer(id), do: id

  defp invalidar_cache_de_rol(rol_id) do
    from(ur in UsuarioRol, where: ur.rol_id == ^rol_id and is_nil(ur.delete_guid))
    |> Repo.all()
    |> Enum.each(&invalidar_cache(&1.usuario_id, &1.empresa_id))
  end

  ## Búsqueda para la UI (Fase 2 Paso 6b) — pensada para +1000 catálogos:
  ## nunca se carga el universo completo a memoria, todo pasa por
  ## ilike + limit contra la base.

  @doc """
  Catálogos reales (meta_schema_header) que matchean la búsqueda, tope 20
  — nunca la lista completa. Quedan afuera a propósito:

  - Catálogos detalle (`schema_encabezado_id` no nulo) — se administran
    desde el maestro, no tienen permisos propios.
  - Catálogos sin ningún estado/transición configurado todavía (recién
    graduados del wizard, sin motor de estados armado) — no hay nada que
    conceder ahí hasta que tengan al menos una transición real.
  - Excepción: catálogos tipo 3 (Consulta Ecto, de solo lectura — ver
    MetaConsultas) nunca tienen motor de estados por diseño, así que se
    dejan pasar sin exigirles ninguna transición.
  """
  def buscar_catalogos(query, limite \\ 20)

  def buscar_catalogos("", _limite), do: []

  def buscar_catalogos(query, limite) do
    texto = "%#{query}%"

    Repo.all(
      from h in Header,
        as: :header,
        where:
          is_nil(h.delete_guid) and h.schema_context_type != 2 and is_nil(h.schema_encabezado_id) and
            (ilike(h.schema_context_name, ^texto) or ilike(h.schema_context_label, ^texto)) and
            (h.schema_context_type == 3 or
               exists(
                 from t in "meta_schema_transiciones",
                   where: t.meta_schema_header_id == parent_as(:header).id and is_nil(t.delete_guid),
                   select: 1
               )),
        order_by: h.schema_context_label,
        limit: ^limite,
        select: %{recurso: h.schema_context_name, label: h.schema_context_label, es_consulta: h.schema_context_type == 3}
    )
  end

  @doc """
  Para una lista de recursos (catálogos), el estado de las 4 acciones
  estándar (CRUD genérico + "leer" que poda el menú) contra un rol. Delega
  en `estado_permisos_para_pares/2` con el producto cartesiano recursos ×
  @acciones.
  """
  def estado_permisos_para_catalogos(rol_id, recursos) when is_list(recursos) do
    pares = for recurso <- recursos, accion <- @acciones, do: {recurso, accion}
    estado_permisos_para_pares(rol_id, pares)
  end

  @doc """
  Igual que `estado_permisos_para_catalogos/2` pero para una lista
  explícita de pares `{recurso, accion}` — usado para transiciones reales
  del motor de estados, donde cada catálogo tiene su propio vocabulario de
  acciones (no siempre las 4 CRUD). Dos queries batch, nunca una por par.
  """
  def estado_permisos_para_pares(_rol_id, []), do: %{}

  def estado_permisos_para_pares(rol_id, pares) when is_list(pares) do
    recursos = pares |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
    acciones = pares |> Enum.map(&elem(&1, 1)) |> Enum.uniq()

    permisos =
      Repo.all(
        from p in Permiso,
          where: p.recurso in ^recursos and p.accion in ^acciones and is_nil(p.delete_guid)
      )

    permiso_ids = Enum.map(permisos, & &1.id)

    concedidos =
      if permiso_ids == [] do
        MapSet.new()
      else
        from(rp in RolPermiso,
          where: rp.rol_id == ^rol_id and rp.permiso_id in ^permiso_ids and is_nil(rp.delete_guid),
          select: rp.permiso_id
        )
        |> Repo.all()
        |> MapSet.new()
      end

    permisos_por_clave = Map.new(permisos, &{{&1.recurso, &1.accion}, &1})

    for {recurso, accion} <- pares, into: %{} do
      case Map.get(permisos_por_clave, {recurso, accion}) do
        nil ->
          {{recurso, accion}, %{permiso_id: nil, concedido: false}}

        permiso ->
          {{recurso, accion}, %{permiso_id: permiso.id, concedido: MapSet.member?(concedidos, permiso.id)}}
      end
    end
  end

  @doc """
  Acciones distintas de las transiciones reales de una lista de catálogos
  (motor de estados) — `%{recurso => [%{accion:, etiqueta:}, ...]}`, una
  sola query batch para todos, nunca una por catálogo.
  """
  def transiciones_de_catalogos(recursos) when is_list(recursos) do
    Repo.all(
      from t in "meta_schema_transiciones",
        join: h in "meta_schema_header",
        on: h.id == t.meta_schema_header_id,
        where: h.schema_context_name in ^recursos and is_nil(t.delete_guid) and is_nil(h.delete_guid),
        distinct: [h.schema_context_name, t.accion],
        select: %{recurso: h.schema_context_name, accion: t.accion, etiqueta: t.etiqueta}
    )
    |> Enum.group_by(& &1.recurso, &Map.take(&1, [:accion, :etiqueta]))
  end

  @doc """
  Concede un permiso de catálogo a un rol — da de alta el permiso si
  todavía no existe (CRUD manual, ver Paso 6) y lo vincula en el mismo
  paso, para que la UI no obligue a un alta separada antes de poder tildar
  la casilla.
  """
  def conceder_permiso_catalogo(rol_id, recurso, accion) do
    permiso =
      case Repo.get_by(Permiso, recurso: recurso, accion: accion) do
        nil ->
          {:ok, permiso} = crear_permiso(%{recurso: recurso, accion: accion})
          permiso

        permiso ->
          permiso
      end

    case Repo.get_by(RolPermiso, rol_id: rol_id, permiso_id: permiso.id) do
      nil -> asignar_permiso_a_rol(rol_id, permiso.id)
      _ya_existe -> {:ok, :ya_concedido}
    end
    |> tap(fn _ -> invalidar_cache_de_rol(rol_id) end)
  end

  @doc "Revoca (borra el vínculo) un permiso puntual de un rol — el permiso en sí sigue existiendo para otros roles."
  def revocar_permiso_de_rol(rol_id, permiso_id) do
    resultado =
      case Repo.get_by(RolPermiso, rol_id: rol_id, permiso_id: permiso_id) do
        nil -> {:error, :no_encontrado}
        rol_permiso -> Repo.delete(rol_permiso)
      end

    invalidar_cache_de_rol(rol_id)
    resultado
  end

  @doc "Usuarios que ya pertenecen a la empresa y matchean la búsqueda por email — tope 20."
  def buscar_usuarios_de_la_empresa(empresa_id, query, limite \\ 20)

  def buscar_usuarios_de_la_empresa(_empresa_id, "", _limite), do: []

  def buscar_usuarios_de_la_empresa(empresa_id, query, limite) do
    texto = "%#{query}%"

    Repo.all(
      from u in Usuario,
        join: ue in UsuarioEmpresa,
        on: ue.usuario_id == u.id and is_nil(ue.delete_guid),
        where: ue.empresa_id == ^empresa_id and ilike(u.email, ^texto),
        order_by: u.email,
        limit: ^limite
    )
  end

  @doc "Usuarios con este rol concedido en una empresa (para listarlos/quitarlos)."
  def usuarios_del_rol(rol_id, empresa_id) do
    Repo.all(
      from u in Usuario,
        join: ur in UsuarioRol,
        on: ur.usuario_id == u.id and is_nil(ur.delete_guid),
        where: ur.rol_id == ^rol_id and ur.empresa_id == ^empresa_id,
        order_by: u.email
    )
  end

  @doc "Roles que tiene asignados un usuario puntual en una empresa (inverso de usuarios_del_rol/2)."
  def roles_de_usuario(usuario_id, empresa_id) do
    Repo.all(
      from r in Rol,
        join: ur in UsuarioRol,
        on: ur.rol_id == r.id and is_nil(ur.delete_guid),
        where: ur.usuario_id == ^usuario_id and ur.empresa_id == ^empresa_id and is_nil(r.delete_guid),
        order_by: r.nombre
    )
  end

  @doc """
  De una lista de recursos, cuáles califican para tener permisos propios:
  no son catálogo detalle (`schema_encabezado_id` nulo) y tienen al menos
  una transición configurada — misma regla que `buscar_catalogos/2`, acá
  en forma de `MapSet` para anotar filas ya cargadas (ej. `BcListLive`)
  sin una query por fila.
  """
  def catalogos_con_permisos_habilitados(recursos) when is_list(recursos) do
    Repo.all(
      from h in Header,
        as: :header,
        where:
          h.schema_context_name in ^recursos and is_nil(h.delete_guid) and is_nil(h.schema_encabezado_id) and
            exists(
              from t in "meta_schema_transiciones",
                where: t.meta_schema_header_id == parent_as(:header).id and is_nil(t.delete_guid),
                select: 1
            ),
        select: h.schema_context_name
    )
    |> MapSet.new()
  end

  @doc "Un catálogo puntual por recurso, para encabezados (nil si no existe o está borrado)."
  def obtener_catalogo(recurso) do
    Repo.one(
      from h in Header,
        where: h.schema_context_name == ^recurso and is_nil(h.delete_guid),
        select: %{
          recurso: h.schema_context_name,
          label: h.schema_context_label,
          es_consulta: h.schema_context_type == 3,
          es_detalle: not is_nil(h.schema_encabezado_id)
        }
    )
  end

  @doc """
  Vista invertida de `estado_permisos_para_pares/2`: un catálogo fijo, el
  estado de cada acción contra una lista de roles — para la pantalla "veo
  todos los roles de este catálogo" (Fase A del roadmap). Dos queries
  batch, nunca una por rol. `administrador` se marca concedido en
  cualquier acción que YA exista como permiso registrado, sin necesitar
  `rol_permiso` — mismo criterio que en todo el resto de RBAC.
  """
  def estado_permisos_para_roles(_recurso, [], _acciones), do: %{}
  def estado_permisos_para_roles(_recurso, _rol_ids, []), do: %{}

  def estado_permisos_para_roles(recurso, rol_ids, acciones) do
    permisos =
      Repo.all(
        from p in Permiso,
          where: p.recurso == ^recurso and p.accion in ^acciones and is_nil(p.delete_guid)
      )

    permiso_ids = Enum.map(permisos, & &1.id)
    acciones_registradas = MapSet.new(permisos, & &1.accion)

    concedidos =
      if permiso_ids == [] do
        MapSet.new()
      else
        from(rp in RolPermiso,
          where: rp.rol_id in ^rol_ids and rp.permiso_id in ^permiso_ids and is_nil(rp.delete_guid),
          select: {rp.rol_id, rp.permiso_id}
        )
        |> Repo.all()
        |> MapSet.new()
      end

    roles_administradores =
      rol_ids
      |> Enum.filter(fn rol_id -> administrador_es_sistema?(rol_id) end)
      |> MapSet.new()

    permisos_por_accion = Map.new(permisos, &{&1.accion, &1})

    for rol_id <- rol_ids, accion <- acciones, into: %{} do
      case Map.get(permisos_por_accion, accion) do
        nil ->
          {{rol_id, accion}, %{permiso_id: nil, concedido: false}}

        permiso ->
          concedido =
            MapSet.member?(concedidos, {rol_id, permiso.id}) or
              (MapSet.member?(roles_administradores, rol_id) and MapSet.member?(acciones_registradas, accion))

          {{rol_id, accion}, %{permiso_id: permiso.id, concedido: concedido}}
      end
    end
  end

  defp administrador_es_sistema?(rol_id) do
    Repo.exists?(from r in Rol, where: r.id == ^rol_id and r.es_sistema == true and r.nombre == "administrador")
  end

  defp generar_guid do
    Ecto.UUID.generate() |> String.replace("-", "")
  end
end
