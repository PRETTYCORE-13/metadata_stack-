defmodule MetadataApp.Autenticacion do
  @moduledoc """
  The Autenticacion context.
  """

  import Ecto.Query, warn: false
  alias MetadataApp.Repo

  alias MetadataApp.Autenticacion.{
    Usuario,
    UsuarioToken,
    UsuarioNotifier,
    Empresa,
    UsuarioEmpresa,
    UsuarioRol,
    Rol,
    Branch,
    SalesUnit,
    InventoryLocation,
    UsuarioBranch,
    UsuarioSalesUnit,
    UsuarioInventoryLocation
  }

  ## Empresas (tenant) del usuario — un usuario puede tener varias; la que
  ## use en un momento dado queda en el Scope (`empresa_activa`), elegida
  ## por un selector post-login cuando tiene más de una.

  @doc "Lista las empresas a las que un usuario tiene acceso, ordenadas por nombre."
  def empresas_de_usuario(usuario_id) do
    from(e in Empresa,
      join: ue in UsuarioEmpresa,
      on: ue.empresa_id == e.id and is_nil(ue.delete_guid),
      where: ue.usuario_id == ^usuario_id and is_nil(e.delete_guid),
      order_by: e.nombre
    )
    |> Repo.all()
  end

  @doc "Todas las empresas del sistema — a diferencia de empresas_de_usuario/1, sin filtrar por ningún usuario. Usado en la pantalla de administración de usuarios para poder agregar CUALQUIER empresa a alguien, no solo las del admin que la está usando."
  def listar_empresas do
    from(e in Empresa, where: is_nil(e.delete_guid), order_by: e.nombre) |> Repo.all()
  end

  @doc "Confirma que el usuario tiene acceso a esa empresa antes de activarla en el Scope."
  def obtener_empresa_de_usuario(usuario_id, empresa_id) do
    from(e in Empresa,
      join: ue in UsuarioEmpresa,
      on: ue.empresa_id == e.id and is_nil(ue.delete_guid),
      where: ue.usuario_id == ^usuario_id and e.id == ^empresa_id and is_nil(e.delete_guid)
    )
    |> Repo.one()
  end

  @doc """
  Empresa "default" del usuario (2026-08-12) -- la que
  `UsuarioAuth.log_in_usuario/2` auto-activa al login SIN mandarlo a
  `/seleccionar-empresa`, aunque pertenezca a 2+. Revalida contra la
  membresía VIVA en cada lectura (mismo criterio que
  `obtener_branch_de_usuario/4` etc.): si le quitaron acceso a esa
  empresa después de marcarla default, esto devuelve `nil` en vez de
  arrastrar una referencia a algo que ya no puede usar.
  """
  def empresa_default_de_usuario(usuario_id) do
    case Repo.get(Usuario, usuario_id) |> Repo.preload(:empresa_default) do
      %{empresa_default: nil} -> nil
      %{empresa_default: empresa} -> obtener_empresa_de_usuario(usuario_id, empresa.id)
    end
  end

  @doc "Fija (o limpia, con `nil`) la empresa default -- nunca confía en el id sin revalidar que el usuario de verdad pertenece a esa empresa."
  def definir_empresa_default(usuario_id, nil) do
    atualizar_empresa_default(usuario_id, %{"empresa_default_id" => nil})
  end

  def definir_empresa_default(usuario_id, empresa_id) do
    if obtener_empresa_de_usuario(usuario_id, empresa_id) do
      atualizar_empresa_default(usuario_id, %{"empresa_default_id" => empresa_id})
    else
      {:error, :fuera_de_alcance}
    end
  end

  defp atualizar_empresa_default(usuario_id, attrs) do
    case Repo.get(Usuario, usuario_id) do
      nil -> {:error, :no_encontrado}
      usuario -> usuario |> Usuario.changeset_empresa_default(attrs) |> Repo.update()
    end
  end

  @doc """
  Crea una empresa nueva y deja al usuario creador como miembro +
  `administrador` ahí, todo en la misma transacción — si no, quedaría un
  tenant al que nadie podría entrar después (mismo motivo por el que
  existe unirse_como_admin/2 — un usuario.super_admin siempre tiene esta
  puerta de rescate para una empresa YA existente).
  """
  def crear_empresa_para_usuario(nombre, usuario_id) do
    Repo.transaction(fn ->
      with {:ok, empresa} <-
             %Empresa{}
             |> Empresa.changeset(%{nombre: nombre})
             |> Ecto.Changeset.change(%{insert_guid: generar_guid()})
             |> Repo.insert(),
           {:ok, _} <-
             %UsuarioEmpresa{}
             |> UsuarioEmpresa.changeset(%{usuario_id: usuario_id, empresa_id: empresa.id})
             |> Ecto.Changeset.change(%{insert_guid: generar_guid()})
             |> Repo.insert(),
           rol_admin <- Repo.get_by!(Rol, nombre: "administrador"),
           {:ok, _} <- MetadataApp.Permissions.asignar_rol(usuario_id, rol_admin.id, empresa.id) do
        empresa
      else
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  @doc """
  Puerta de rescate para un usuario.super_admin: unirse como
  `administrador` a una empresa YA EXISTENTE de la que todavía no es
  miembro (a diferencia de crear_empresa_para_usuario/2, que crea el
  tenant). Sin esto, un super_admin podía VER todas las empresas
  (Autenticacion.listar_empresas/0) pero no entrar a ninguna que no
  fuera propia — el mismo hueco que crear_empresa_para_usuario/2 ya
  resuelve para una empresa nueva. No-op si ya era miembro.
  """
  def unirse_como_admin(usuario_id, empresa_id) do
    case obtener_empresa_de_usuario(usuario_id, empresa_id) do
      nil ->
        Repo.transaction(fn ->
          with {:ok, _} <-
                 %UsuarioEmpresa{}
                 |> UsuarioEmpresa.changeset(%{usuario_id: usuario_id, empresa_id: empresa_id})
                 |> Ecto.Changeset.change(%{insert_guid: generar_guid()})
                 |> Repo.insert(),
               rol_admin <- Repo.get_by!(Rol, nombre: "administrador"),
               {:ok, _} <- MetadataApp.Permissions.asignar_rol(usuario_id, rol_admin.id, empresa_id) do
            :ok
          else
            {:error, changeset} -> Repo.rollback(changeset)
          end
        end)

      _ya_miembro ->
        {:ok, :ya_miembro}
    end
  end

  @doc """
  Mapa `%{empresa_id => cantidad}` de usuarios activos por empresa, para
  que la UI decida si puede ofrecer "Eliminar" sin una query por fila
  (N+1) — empresas sin ninguna fila acá simplemente no aparecen en el
  mapa (tratar como 0 con `Map.get/3`).
  """
  def contar_usuarios_por_empresa(empresa_ids) do
    from(ue in UsuarioEmpresa,
      where: ue.empresa_id in ^empresa_ids and is_nil(ue.delete_guid),
      group_by: ue.empresa_id,
      select: {ue.empresa_id, count(ue.id)}
    )
    |> Repo.all()
    |> Map.new()
  end

  @doc """
  Soft-delete de una empresa — bloqueado si todavía tiene algún usuario
  asociado (mismo criterio que `MetaEstadosAdmin.eliminar_estado/1`:
  mejor un mensaje claro acá que dejar usuarios con un `empresa_id`
  huérfano). No hace falta revisar roles/permisos por separado: sin
  usuarios ya no hay a quién le apliquen.
  """
  def eliminar_empresa(%Empresa{} = empresa) do
    if tiene_usuarios?(empresa.id) do
      {:error, :tiene_usuarios}
    else
      empresa
      |> Ecto.Changeset.change(%{delete_guid: generar_guid()})
      |> Repo.update()
    end
  end

  defp tiene_usuarios?(empresa_id) do
    Repo.exists?(from ue in UsuarioEmpresa, where: ue.empresa_id == ^empresa_id and is_nil(ue.delete_guid))
  end

  @doc "Solo el nombre por ahora — crear/editar más campos de empresa queda para cuando haga falta."
  def actualizar_empresa(empresa, attrs) do
    empresa
    |> Empresa.changeset(attrs)
    |> Ecto.Changeset.change(%{update_guid: generar_guid()})
    |> Repo.update()
  end

  defp generar_guid do
    Ecto.UUID.generate() |> String.replace("-", "")
  end

  ## Jerarquía organizacional (Fase 0 del modelo de Alcance de Datos,
  ## 2026-08-11) -- Empresa -> Branch -> {SalesUnit, InventoryLocation}.
  ## Mismo trato de sistema que Empresa arriba: CRUD simple con soft-delete,
  ## sin transacciones combinadas (a diferencia de crear_empresa_para_usuario/2,
  ## acá no hay un "dueño" que asignar al crear).

  @doc "Sucursales vivas de una empresa, orden alfabético."
  def listar_branches(empresa_id) do
    from(b in Branch, where: b.empresa_id == ^empresa_id and is_nil(b.delete_guid), order_by: b.branch_name)
    |> Repo.all()
  end

  def crear_branch(attrs) do
    %Branch{}
    |> Branch.changeset(attrs)
    |> Ecto.Changeset.change(%{insert_guid: generar_guid()})
    |> Repo.insert()
  end

  def actualizar_branch(%Branch{} = branch, attrs) do
    branch
    |> Branch.changeset(attrs)
    |> Ecto.Changeset.change(%{update_guid: generar_guid()})
    |> Repo.update()
  end

  @doc "Bloqueado si la sucursal todavía tiene alguna Sales Unit o Inventory Location viva -- mismo criterio que eliminar_empresa/1."
  def eliminar_branch(%Branch{} = branch) do
    if tiene_hijos_vivos?(SalesUnit, :branch_id, branch.id) or tiene_hijos_vivos?(InventoryLocation, :branch_id, branch.id) do
      {:error, :tiene_hijos}
    else
      branch |> Ecto.Changeset.change(%{delete_guid: generar_guid()}) |> Repo.update()
    end
  end

  @doc "Sales Units vivas de una sucursal, orden alfabético."
  def listar_sales_units(branch_id) do
    from(s in SalesUnit, where: s.branch_id == ^branch_id and is_nil(s.delete_guid), order_by: s.sales_unit_name)
    |> Repo.all()
  end

  @doc "Sales Units vivas de TODA una empresa (todas sus branches juntas), orden alfabético -- usado por el selector de jerarquía operativa cuando el usuario es administrador (ve todas, no solo las asignadas, ver MenuLayout/JerarquiaSessionController)."
  def listar_sales_units_de_empresa(empresa_id) do
    from(s in SalesUnit, where: s.empresa_id == ^empresa_id and is_nil(s.delete_guid), order_by: s.sales_unit_name)
    |> Repo.all()
  end

  def crear_sales_unit(attrs) do
    %SalesUnit{}
    |> SalesUnit.changeset(attrs)
    |> Ecto.Changeset.change(%{insert_guid: generar_guid()})
    |> Repo.insert()
  end

  def actualizar_sales_unit(%SalesUnit{} = sales_unit, attrs) do
    sales_unit
    |> SalesUnit.changeset(attrs)
    |> Ecto.Changeset.change(%{update_guid: generar_guid()})
    |> Repo.update()
  end

  def eliminar_sales_unit(%SalesUnit{} = sales_unit) do
    sales_unit |> Ecto.Changeset.change(%{delete_guid: generar_guid()}) |> Repo.update()
  end

  @doc "Inventory Locations vivas de una sucursal, orden alfabético."
  def listar_inventory_locations(branch_id) do
    from(i in InventoryLocation, where: i.branch_id == ^branch_id and is_nil(i.delete_guid), order_by: i.inventory_name)
    |> Repo.all()
  end

  @doc "Inventory Locations vivas de TODA una empresa (todas sus branches juntas), orden alfabético -- mismo motivo que listar_sales_units_de_empresa/1."
  def listar_inventory_locations_de_empresa(empresa_id) do
    from(i in InventoryLocation, where: i.empresa_id == ^empresa_id and is_nil(i.delete_guid), order_by: i.inventory_name)
    |> Repo.all()
  end

  def crear_inventory_location(attrs) do
    %InventoryLocation{}
    |> InventoryLocation.changeset(attrs)
    |> Ecto.Changeset.change(%{insert_guid: generar_guid()})
    |> Repo.insert()
  end

  def actualizar_inventory_location(%InventoryLocation{} = inventory_location, attrs) do
    inventory_location
    |> InventoryLocation.changeset(attrs)
    |> Ecto.Changeset.change(%{update_guid: generar_guid()})
    |> Repo.update()
  end

  def eliminar_inventory_location(%InventoryLocation{} = inventory_location) do
    inventory_location |> Ecto.Changeset.change(%{delete_guid: generar_guid()}) |> Repo.update()
  end

  defp tiene_hijos_vivos?(schema_mod, campo_padre, padre_id) do
    Repo.exists?(from h in schema_mod, where: field(h, ^campo_padre) == ^padre_id and is_nil(h.delete_guid))
  end

  ## Asignación de alcance al usuario (Fase 2 del modelo de Alcance de
  ## Datos, 2026-08-11) -- 3 tablas N:N, mismo patrón que
  ## empresas_de_usuario/1 arriba. Alimenta Scope.branches_permitidos/
  ## sales_units_permitidas/inventory_locations_permitidas (ver
  ## UsuarioAuth.hidratar_alcance/2) -- el "QUÉ TIPO de alcance aplica" NO
  ## vive acá ni en el Scope (ver el moduledoc de Scope, corregido en
  ## Fase 3): es una función de (rol, catálogo), resuelta en
  ## MetadataApp.Permissions.alcance_tipo_efectivo/2.

  @doc "Branches asignadas a un usuario, acotadas a una empresa (defensivo -- un usuario_branch nunca debería cruzar de empresa, pero no confiar en eso sin filtrar)."
  def branches_de_usuario(usuario_id, empresa_id) do
    from(b in Branch,
      join: ub in UsuarioBranch,
      on: ub.branch_id == b.id and is_nil(ub.delete_guid),
      where: ub.usuario_id == ^usuario_id and b.empresa_id == ^empresa_id and is_nil(b.delete_guid),
      order_by: b.branch_name
    )
    |> Repo.all()
  end

  def asignar_branch(usuario_id, branch_id) do
    %UsuarioBranch{}
    |> UsuarioBranch.changeset(%{usuario_id: usuario_id, branch_id: branch_id})
    |> Ecto.Changeset.change(%{insert_guid: generar_guid()})
    |> Repo.insert(on_conflict: :nothing, conflict_target: [:usuario_id, :branch_id])
  end

  def revocar_branch(usuario_id, branch_id) do
    from(ub in UsuarioBranch, where: ub.usuario_id == ^usuario_id and ub.branch_id == ^branch_id)
    |> Repo.delete_all()
  end

  @doc "Sales Units asignadas a un usuario, acotadas a una empresa."
  def sales_units_de_usuario(usuario_id, empresa_id) do
    from(s in SalesUnit,
      join: us in UsuarioSalesUnit,
      on: us.sales_unit_id == s.id and is_nil(us.delete_guid),
      where: us.usuario_id == ^usuario_id and s.empresa_id == ^empresa_id and is_nil(s.delete_guid),
      order_by: s.sales_unit_name
    )
    |> Repo.all()
  end

  def asignar_sales_unit(usuario_id, sales_unit_id) do
    %UsuarioSalesUnit{}
    |> UsuarioSalesUnit.changeset(%{usuario_id: usuario_id, sales_unit_id: sales_unit_id})
    |> Ecto.Changeset.change(%{insert_guid: generar_guid()})
    |> Repo.insert(on_conflict: :nothing, conflict_target: [:usuario_id, :sales_unit_id])
  end

  def revocar_sales_unit(usuario_id, sales_unit_id) do
    from(us in UsuarioSalesUnit, where: us.usuario_id == ^usuario_id and us.sales_unit_id == ^sales_unit_id)
    |> Repo.delete_all()
  end

  @doc "Inventory Locations asignadas a un usuario, acotadas a una empresa."
  def inventory_locations_de_usuario(usuario_id, empresa_id) do
    from(i in InventoryLocation,
      join: ui in UsuarioInventoryLocation,
      on: ui.inventory_id == i.id and is_nil(ui.delete_guid),
      where: ui.usuario_id == ^usuario_id and i.empresa_id == ^empresa_id and is_nil(i.delete_guid),
      order_by: i.inventory_name
    )
    |> Repo.all()
  end

  def asignar_inventory_location(usuario_id, inventory_id) do
    %UsuarioInventoryLocation{}
    |> UsuarioInventoryLocation.changeset(%{usuario_id: usuario_id, inventory_id: inventory_id})
    |> Ecto.Changeset.change(%{insert_guid: generar_guid()})
    |> Repo.insert(on_conflict: :nothing, conflict_target: [:usuario_id, :inventory_id])
  end

  def revocar_inventory_location(usuario_id, inventory_id) do
    from(ui in UsuarioInventoryLocation, where: ui.usuario_id == ^usuario_id and ui.inventory_id == ^inventory_id)
    |> Repo.delete_all()
  end

  @doc """
  Resuelve las 3 listas de ids permitidos (branches/sales_units/inventory_locations)
  de un usuario en una empresa, en un solo mapa -- lo que UsuarioAuth usa
  para hidratar el Scope en cada mount/request (ver hidratar_alcance/2 ahí).
  Simples ids, no structs completos -- es lo único que necesita el WHERE
  de aplicar_alcance_de_datos/3 (Fase 4a/4b, todavía no construida).
  """
  def alcance_de_usuario(usuario_id, empresa_id) do
    %{
      branches_permitidos: branches_de_usuario(usuario_id, empresa_id) |> Enum.map(& &1.id),
      sales_units_permitidas: sales_units_de_usuario(usuario_id, empresa_id) |> Enum.map(& &1.id),
      inventory_locations_permitidas: inventory_locations_de_usuario(usuario_id, empresa_id) |> Enum.map(& &1.id)
    }
  end

  @doc """
  Resuelve, para las 3 dimensiones de la jerarquía operativa (branch/
  inventory_location/sales_unit), si hay que auto-activar una (el usuario
  solo tiene una permitida en esa empresa — mismo criterio que ya usa
  `UsuarioAuth.log_in_usuario/2` con `empresa_activa_id`), si hace falta
  pedirle que elija (2+ permitidas) o si no tiene ninguna asignada
  todavía. `branch`/`inventory_location` son obligatorios de operar;
  `sales_unit` es el único opcional de los tres -- un `{:vacio}` ahí no
  bloquea nada, los otros dos sí (ver UsuarioAuth/SeleccionarJerarquiaLive,
  que consumen esto para decidir si redirigir a elegir o dejar pasar).

  `es_administrador?` (default `false`, el caller lo resuelve con
  `MetadataApp.Permissions.administrador?/2` -- este módulo no depende de
  Permissions, es una capa "arriba") -- un administrador bypasea
  alcance_tipo_efectivo/2 por completo, así que acá también ve TODAS las
  branches/inventory_locations/sales_units de la empresa, no solo las
  explícitamente asignadas en usuario_branch/etc (que probablemente ni
  tenga, es sysadmin) -- encontrado en vivo: sin esto, el selector de la
  banda de pie (MenuLayout) le mostraba "Empresa" pero nada de
  branch/inventory, porque las listas asignadas volvían vacías.
  """
  def resolver_jerarquia_operativa(usuario_id, empresa_id, es_administrador? \\ false) do
    defaults = defaults_de_usuario(usuario_id, empresa_id)

    %{
      branch: seleccion_con_default(branches_operables(usuario_id, empresa_id, es_administrador?), defaults.branch),
      inventory_location:
        seleccion_con_default(inventory_locations_operables(usuario_id, empresa_id, es_administrador?), defaults.inventory_location),
      sales_unit: seleccion_con_default(sales_units_operables(usuario_id, empresa_id, es_administrador?), defaults.sales_unit)
    }
  end

  # Un default configurado (2026-08-12, ver defaults_de_usuario/2) gana
  # sobre el criterio de "auto-activa solo si hay exactamente 1" -- pero
  # se revalida que siga entre lo operable ANTES de confiar en él (mismo
  # criterio de "revalidar en cada hidratación" que ya usa
  # hidratar_empresa_activa/2): si le revocaron el acceso a esa branch
  # después de marcarla default, cae al criterio de siempre en vez de
  # arrastrar una referencia que ya no debería poder operar.
  defp seleccion_con_default(operables, %{id: default_id} = default) do
    if Enum.any?(operables, &(&1.id == default_id)) do
      {:automatico, default}
    else
      seleccion_automatica_o_pendiente(operables)
    end
  end

  defp seleccion_con_default(operables, nil), do: seleccion_automatica_o_pendiente(operables)

  defp seleccion_automatica_o_pendiente([]), do: {:vacio}
  defp seleccion_automatica_o_pendiente([unica]), do: {:automatico, unica}
  defp seleccion_automatica_o_pendiente(varias), do: {:pendiente, varias}

  defp branches_operables(_usuario_id, empresa_id, true), do: listar_branches(empresa_id)
  defp branches_operables(usuario_id, empresa_id, false), do: branches_de_usuario(usuario_id, empresa_id)

  defp inventory_locations_operables(_usuario_id, empresa_id, true), do: listar_inventory_locations_de_empresa(empresa_id)
  defp inventory_locations_operables(usuario_id, empresa_id, false), do: inventory_locations_de_usuario(usuario_id, empresa_id)

  defp sales_units_operables(_usuario_id, empresa_id, true), do: listar_sales_units_de_empresa(empresa_id)
  defp sales_units_operables(usuario_id, empresa_id, false), do: sales_units_de_usuario(usuario_id, empresa_id)

  @doc "El branch operable por el usuario en esa empresa cuyo id coincide, o nil -- nunca confiar en un id que llega de sesión/form sin revalidar (mismo criterio que obtener_empresa_de_usuario/2). `es_administrador?` amplía el universo a TODAS las branches de la empresa, ver resolver_jerarquia_operativa/3."
  def obtener_branch_de_usuario(usuario_id, empresa_id, branch_id, es_administrador? \\ false),
    do: Enum.find(branches_operables(usuario_id, empresa_id, es_administrador?), &(&1.id == branch_id))

  @doc "Igual que obtener_branch_de_usuario/4, para Sales Unit."
  def obtener_sales_unit_de_usuario(usuario_id, empresa_id, sales_unit_id, es_administrador? \\ false),
    do: Enum.find(sales_units_operables(usuario_id, empresa_id, es_administrador?), &(&1.id == sales_unit_id))

  @doc "Igual que obtener_branch_de_usuario/4, para Inventory Location."
  def obtener_inventory_location_de_usuario(usuario_id, empresa_id, inventory_id, es_administrador? \\ false),
    do: Enum.find(inventory_locations_operables(usuario_id, empresa_id, es_administrador?), &(&1.id == inventory_id))

  @doc """
  Branch/Sales Unit/Inventory Location "default" del usuario en esa
  empresa (2026-08-12) -- lo que un admin pre-configuró para que el
  login lo auto-active, distinto de "permitido" (branches_de_usuario/2
  etc, el universo asignado) y de "activo" (Scope, de la sesión). `nil`
  en cualquiera de los 3 = sin default configurado para esa dimensión
  (el login cae al criterio de siempre: auto-activa si hay exactamente 1
  permitida). Ver UsuariosEmpresaLive, pestaña Alcance, botón "Default".
  """
  def defaults_de_usuario(usuario_id, empresa_id) do
    case Repo.get_by(UsuarioEmpresa, usuario_id: usuario_id, empresa_id: empresa_id) do
      nil ->
        %{branch: nil, sales_unit: nil, inventory_location: nil}

      usuario_empresa ->
        usuario_empresa = Repo.preload(usuario_empresa, [:branch_default, :sales_unit_default, :inventory_default])
        %{branch: usuario_empresa.branch_default, sales_unit: usuario_empresa.sales_unit_default, inventory_location: usuario_empresa.inventory_default}
    end
  end

  @doc """
  Fija (o limpia, con `nil`) el branch default de un usuario en una
  empresa -- nunca confía en el id sin revalidar que sigue entre las
  branches PERMITIDAS del usuario (no tiene sentido un default fuera de
  lo que puede operar); `{:error, :fuera_de_alcance}` si no lo está.
  """
  def definir_branch_default(usuario_id, empresa_id, branch_id, es_administrador? \\ false) do
    definir_default(usuario_id, empresa_id, :branch_default_id, branch_id, fn u, e, id ->
      obtener_branch_de_usuario(u, e, id, es_administrador?)
    end)
  end

  @doc "Igual que definir_branch_default/3, para Sales Unit."
  def definir_sales_unit_default(usuario_id, empresa_id, sales_unit_id, es_administrador? \\ false) do
    definir_default(usuario_id, empresa_id, :sales_unit_default_id, sales_unit_id, fn u, e, id ->
      obtener_sales_unit_de_usuario(u, e, id, es_administrador?)
    end)
  end

  @doc "Igual que definir_branch_default/3, para Inventory Location."
  def definir_inventory_location_default(usuario_id, empresa_id, inventory_id, es_administrador? \\ false) do
    definir_default(usuario_id, empresa_id, :inventory_default_id, inventory_id, fn u, e, id ->
      obtener_inventory_location_de_usuario(u, e, id, es_administrador?)
    end)
  end

  defp definir_default(usuario_id, empresa_id, campo, nil, _validador) do
    atualizar_usuario_empresa(usuario_id, empresa_id, %{Atom.to_string(campo) => nil})
  end

  defp definir_default(usuario_id, empresa_id, campo, id, validador) do
    case validador.(usuario_id, empresa_id, id) do
      nil -> {:error, :fuera_de_alcance}
      _valido -> atualizar_usuario_empresa(usuario_id, empresa_id, %{Atom.to_string(campo) => id})
    end
  end

  defp atualizar_usuario_empresa(usuario_id, empresa_id, attrs) do
    case Repo.get_by(UsuarioEmpresa, usuario_id: usuario_id, empresa_id: empresa_id) do
      nil -> {:error, :no_encontrado}
      usuario_empresa -> usuario_empresa |> UsuarioEmpresa.changeset_default(attrs) |> Repo.update()
    end
  end

  @doc """
  Usuarios ya registrados (por magic-link/self-service) que todavía no
  pertenecen a NINGUNA empresa — sin esto, el admin no tiene forma de
  enterarse de que alguien se registró (nadie le avisa; ver discusión de
  producto: reemplaza el alta "escribir cualquier email" en la pantalla
  de administración de usuarios, que además creaba la cuenta desde cero
  en vez de solo listar las que ya existen). Más recientes primero — son
  las que un admin quiere ver primero para darles acceso. Acotado
  (limite 50): mismo criterio de escala que buscar_roles/3/buscar_catalogos/2,
  aunque acá es poco probable que se acumulen cientos sin que alguien note.
  """
  def listar_usuarios_sin_empresa(limite \\ 50) do
    from(u in Usuario,
      as: :usuario,
      where:
        not is_nil(u.confirmed_at) and
          not exists(from ue in UsuarioEmpresa, where: ue.usuario_id == parent_as(:usuario).id and is_nil(ue.delete_guid)),
      order_by: [desc: u.inserted_at],
      limit: ^limite
    )
    |> Repo.all()
  end

  @doc "Usuarios que pertenecen a una empresa, con si su cuenta ya está confirmada."
  def listar_usuarios_de_empresa(empresa_id) do
    from(u in Usuario,
      join: ue in UsuarioEmpresa,
      on: ue.usuario_id == u.id and is_nil(ue.delete_guid),
      where: ue.empresa_id == ^empresa_id,
      order_by: u.email
    )
    |> Repo.all()
  end

  @doc """
  Agrega un usuario a una empresa por email — unifica "agregar a alguien
  que ya tiene cuenta" e "invitar a alguien nuevo" en una sola acción (no
  hay flujo de invitación por email separado todavía: si la cuenta no
  existe, se crea sin contraseña, lista para el login por magic link igual
  que cualquier otra). Es un no-op silencioso si ya era miembro.
  """
  def agregar_usuario_a_empresa(email, empresa_id) do
    usuario =
      case get_usuario_by_email(email) do
        nil ->
          {:ok, usuario} = register_usuario(%{email: email})
          usuario

        usuario ->
          usuario
      end

    case obtener_empresa_de_usuario(usuario.id, empresa_id) do
      nil ->
        %UsuarioEmpresa{}
        |> UsuarioEmpresa.changeset(%{usuario_id: usuario.id, empresa_id: empresa_id})
        |> Repo.insert()

      _ya_miembro ->
        {:ok, usuario}
    end
  end

  @doc """
  Quita a un usuario de una empresa (soft-delete) y revoca cualquier rol
  que tuviera asignado EN ESA empresa — un rol atado a una empresa de la
  que ya no es miembro queda huérfano (ni siquiera podría volver a elegir
  esa empresa para usarlo).
  """
  def remover_usuario_de_empresa(usuario_id, empresa_id) do
    from(ur in UsuarioRol,
      where: ur.usuario_id == ^usuario_id and ur.empresa_id == ^empresa_id and is_nil(ur.delete_guid),
      select: ur.rol_id
    )
    |> Repo.all()
    |> Enum.each(&MetadataApp.Permissions.revocar_rol(usuario_id, &1, empresa_id))

    case Repo.get_by(UsuarioEmpresa, usuario_id: usuario_id, empresa_id: empresa_id) do
      nil ->
        {:error, :no_encontrado}

      usuario_empresa ->
        usuario_empresa
        |> Ecto.Changeset.change(%{delete_guid: Ecto.UUID.generate() |> String.replace("-", "")})
        |> Repo.update()
    end
  end

  ## Database getters

  @doc """
  Gets a usuario by email.

  ## Examples

      iex> get_usuario_by_email("foo@example.com")
      %Usuario{}

      iex> get_usuario_by_email("unknown@example.com")
      nil

  """
  def get_usuario_by_email(email) when is_binary(email) do
    Repo.get_by(Usuario, email: email)
  end

  @doc """
  Gets a usuario by email and password.

  ## Examples

      iex> get_usuario_by_email_and_password("foo@example.com", "correct_password")
      %Usuario{}

      iex> get_usuario_by_email_and_password("foo@example.com", "invalid_password")
      nil

  """
  def get_usuario_by_email_and_password(email, password)
      when is_binary(email) and is_binary(password) do
    usuario = Repo.get_by(Usuario, email: email)
    if Usuario.valid_password?(usuario, password), do: usuario
  end

  @doc """
  Gets a single usuario.

  Raises `Ecto.NoResultsError` if the Usuario does not exist.

  ## Examples

      iex> get_usuario!(123)
      %Usuario{}

      iex> get_usuario!(456)
      ** (Ecto.NoResultsError)

  """
  def get_usuario!(id), do: Repo.get!(Usuario, id)

  ## Usuario registration

  @doc """
  Registers a usuario.

  ## Examples

      iex> register_usuario(%{field: value})
      {:ok, %Usuario{}}

      iex> register_usuario(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def register_usuario(attrs) do
    %Usuario{}
    |> Usuario.email_changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Alta/actualización idempotente del usuario SYSADMIN — bootstrap de un
  sistema nuevo (o rotación de credenciales en uno existente), a partir de
  `email`/`password` que siempre vienen de variables de entorno del
  despliegue (`SYSADMIN_EMAIL`/`SYSADMIN_PASSWORD`, ver
  `MetadataApp.Release.seed_sysadmin/0`) — nunca hardcodeadas en código ni
  en una migración. Login por contraseña (no magic-link: no hace falta que
  el email sea real ni que haya SMTP configurado todavía para poder
  entrar).

  Busca primero por `super_admin: true` (identidad estable aunque
  `SYSADMIN_EMAIL` cambie entre corridas — permite rotar el email sin
  duplicar la cuenta), si no existe ninguna cae a buscar por el email
  dado. Se puede correr en cada deploy sin efecto adverso: si las
  credenciales no cambiaron, el resultado es el mismo usuario con los
  mismos valores.
  """
  def upsert_sysadmin(email, password) do
    usuario = Repo.get_by(Usuario, super_admin: true) || get_usuario_by_email(email) || %Usuario{}

    usuario
    |> Usuario.email_changeset(%{"email" => email}, validate_unique: false)
    |> Usuario.password_changeset(%{"password" => password, "password_confirmation" => password})
    |> Ecto.Changeset.change(%{super_admin: true})
    |> confirmar_si_hace_falta()
    |> Repo.insert_or_update()
  end

  defp confirmar_si_hace_falta(changeset) do
    if is_nil(changeset.data.confirmed_at) do
      Ecto.Changeset.change(changeset, confirmed_at: DateTime.utc_now() |> DateTime.truncate(:second))
    else
      changeset
    end
  end

  ## Settings

  @doc """
  Checks whether the usuario is in sudo mode.

  The usuario is in sudo mode when the last authentication was done no further
  than 20 minutes ago. The limit can be given as second argument in minutes.
  """
  def sudo_mode?(usuario, minutes \\ -20)

  def sudo_mode?(%Usuario{authenticated_at: ts}, minutes) when is_struct(ts, DateTime) do
    DateTime.after?(ts, DateTime.utc_now() |> DateTime.add(minutes, :minute))
  end

  def sudo_mode?(_usuario, _minutes), do: false

  @doc """
  Returns an `%Ecto.Changeset{}` for changing the usuario email.

  See `MetadataApp.Autenticacion.Usuario.email_changeset/3` for a list of supported options.

  ## Examples

      iex> change_usuario_email(usuario)
      %Ecto.Changeset{data: %Usuario{}}

  """
  def change_usuario_email(usuario, attrs \\ %{}, opts \\ []) do
    Usuario.email_changeset(usuario, attrs, opts)
  end

  @doc """
  Updates the usuario email using the given token.

  If the token matches, the usuario email is updated and the token is deleted.
  """
  def update_usuario_email(usuario, token) do
    context = "change:#{usuario.email}"

    Repo.transact(fn ->
      with {:ok, query} <- UsuarioToken.verify_change_email_token_query(token, context),
           %UsuarioToken{sent_to: email} <- Repo.one(query),
           {:ok, usuario} <- Repo.update(Usuario.email_changeset(usuario, %{email: email})),
           {_count, _result} <-
             Repo.delete_all(from(UsuarioToken, where: [usuario_id: ^usuario.id, context: ^context])) do
        {:ok, usuario}
      else
        _ -> {:error, :transaction_aborted}
      end
    end)
  end

  @doc "Returns an `%Ecto.Changeset{}` for changing the usuario alias."
  def change_usuario_alias(usuario, attrs \\ %{}) do
    Usuario.alias_changeset(usuario, attrs)
  end

  @doc "Actualiza el alias del usuario — sin sudo mode ni confirmación, no es un dato sensible."
  def update_usuario_alias(usuario, attrs) do
    usuario
    |> Usuario.alias_changeset(attrs)
    |> Repo.update()
  end

  @doc "Actualiza el avatar (semilla de DiceBear) del usuario — sin sudo mode, no es un dato sensible."
  def update_usuario_avatar(usuario, attrs) do
    usuario
    |> Usuario.avatar_changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Elimina la cuenta directo — Usuario no tiene delete_guid, no hay soft-
  delete acá como en el resto del RBAC. Pensado para "rechazar" a alguien
  que se registró y todavía no pertenece a ninguna empresa (ver
  listar_usuarios_sin_empresa/1): sin ninguna fila en UsuarioEmpresa/
  UsuarioRol que dependa de él, no hay nada que quede huérfano. Los
  tokens de sesión cascadean solos (on_delete: :delete_all).
  """
  def eliminar_usuario(%Usuario{} = usuario), do: Repo.delete(usuario)

  @doc """
  Returns an `%Ecto.Changeset{}` for changing the usuario password.

  See `MetadataApp.Autenticacion.Usuario.password_changeset/3` for a list of supported options.

  ## Examples

      iex> change_usuario_password(usuario)
      %Ecto.Changeset{data: %Usuario{}}

  """
  def change_usuario_password(usuario, attrs \\ %{}, opts \\ []) do
    Usuario.password_changeset(usuario, attrs, opts)
  end

  @doc """
  Updates the usuario password.

  Returns a tuple with the updated usuario, as well as a list of expired tokens.

  ## Examples

      iex> update_usuario_password(usuario, %{password: ...})
      {:ok, {%Usuario{}, [...]}}

      iex> update_usuario_password(usuario, %{password: "too short"})
      {:error, %Ecto.Changeset{}}

  """
  def update_usuario_password(usuario, attrs) do
    usuario
    |> Usuario.password_changeset(attrs)
    |> update_usuario_and_delete_all_tokens()
  end

  ## Session

  @doc """
  Generates a session token.
  """
  def generate_usuario_session_token(usuario) do
    {token, usuario_token} = UsuarioToken.build_session_token(usuario)
    Repo.insert!(usuario_token)
    token
  end

  @doc """
  Gets the usuario with the given signed token.

  If the token is valid `{usuario, token_inserted_at}` is returned, otherwise `nil` is returned.
  """
  def get_usuario_by_session_token(token) do
    {:ok, query} = UsuarioToken.verify_session_token_query(token)
    Repo.one(query)
  end

  @doc """
  Gets the usuario with the given magic link token.
  """
  def get_usuario_by_magic_link_token(token) do
    with {:ok, query} <- UsuarioToken.verify_magic_link_token_query(token),
         {usuario, _token} <- Repo.one(query) do
      usuario
    else
      _ -> nil
    end
  end

  @doc """
  Logs the usuario in by magic link.

  There are three cases to consider:

  1. The usuario has already confirmed their email. They are logged in
     and the magic link is expired.

  2. The usuario has not confirmed their email and no password is set.
     In this case, the usuario gets confirmed, logged in, and all tokens -
     including session ones - are expired. In theory, no other tokens
     exist but we delete all of them for best security practices.

  3. The usuario has not confirmed their email but a password is set.
     This cannot happen in the default implementation but may be the
     source of security pitfalls. See the "Mixing magic link and password registration" section of
     `mix help phx.gen.auth`.
  """
  def login_usuario_by_magic_link(token) do
    {:ok, query} = UsuarioToken.verify_magic_link_token_query(token)

    case Repo.one(query) do
      # Prevent session fixation attacks by disallowing magic links for unconfirmed users with password
      {%Usuario{confirmed_at: nil, hashed_password: hash}, _token} when not is_nil(hash) ->
        raise """
        magic link log in is not allowed for unconfirmed users with a password set!

        This cannot happen with the default implementation, which indicates that you
        might have adapted the code to a different use case. Please make sure to read the
        "Mixing magic link and password registration" section of `mix help phx.gen.auth`.
        """

      {%Usuario{confirmed_at: nil} = usuario, _token} ->
        usuario
        |> Usuario.confirm_changeset()
        |> update_usuario_and_delete_all_tokens()

      {usuario, token} ->
        Repo.delete!(token)
        {:ok, {usuario, []}}

      nil ->
        {:error, :not_found}
    end
  end

  @doc ~S"""
  Delivers the update email instructions to the given usuario.

  ## Examples

      iex> deliver_usuario_update_email_instructions(usuario, current_email, &url(~p"/meta_schema_usuario/settings/confirm-email/#{&1}"))
      {:ok, %{to: ..., body: ...}}

  """
  def deliver_usuario_update_email_instructions(%Usuario{} = usuario, current_email, update_email_url_fun)
      when is_function(update_email_url_fun, 1) do
    {encoded_token, usuario_token} = UsuarioToken.build_email_token(usuario, "change:#{current_email}")

    Repo.insert!(usuario_token)
    UsuarioNotifier.deliver_update_email_instructions(usuario, update_email_url_fun.(encoded_token))
  end

  @doc """
  Delivers the magic link login instructions to the given usuario.
  """
  def deliver_login_instructions(%Usuario{} = usuario, magic_link_url_fun)
      when is_function(magic_link_url_fun, 1) do
    {encoded_token, usuario_token} = UsuarioToken.build_email_token(usuario, "login")
    Repo.insert!(usuario_token)
    UsuarioNotifier.deliver_login_instructions(usuario, magic_link_url_fun.(encoded_token))
  end

  @doc """
  Deletes the signed token with the given context.
  """
  def delete_usuario_session_token(token) do
    Repo.delete_all(from(UsuarioToken, where: [token: ^token, context: "session"]))
    :ok
  end

  @doc """
  Revoca TODAS las sesiones activas de un usuario -- uso administrativo
  (despido, salida de urgencia: cortar acceso YA, sin esperar a que
  expire el token por tiempo). A diferencia de delete_usuario_session_token/1
  (una sola sesión, la propia, en logout normal), esto borra TODOS los
  tokens del usuario sin importar en qué dispositivo/navegador se
  emitieron. Devuelve los tokens borrados para que el caller pueda además
  desconectar los sockets LiveView ya abiertos (ver
  MetadataAppWeb.UsuarioAuth.disconnect_sessions/1) -- borrar el token no
  tumba por sí solo una conexión ya establecida.
  """
  def revocar_sesiones_de_usuario(usuario_id) do
    tokens = Repo.all_by(UsuarioToken, usuario_id: usuario_id)
    Repo.delete_all(from(t in UsuarioToken, where: t.id in ^Enum.map(tokens, & &1.id)))
    tokens
  end

  ## Token helper

  defp update_usuario_and_delete_all_tokens(changeset) do
    Repo.transact(fn ->
      with {:ok, usuario} <- Repo.update(changeset) do
        tokens_to_expire = Repo.all_by(UsuarioToken, usuario_id: usuario.id)

        Repo.delete_all(from(t in UsuarioToken, where: t.id in ^Enum.map(tokens_to_expire, & &1.id)))

        {:ok, {usuario, tokens_to_expire}}
      end
    end)
  end
end
