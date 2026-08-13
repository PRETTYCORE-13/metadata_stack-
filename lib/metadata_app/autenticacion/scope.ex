defmodule MetadataApp.Autenticacion.Scope do
  @moduledoc """
  Defines the scope of the caller to be used throughout the app.

  The `MetadataApp.Autenticacion.Scope` allows public interfaces to receive
  information about the caller, such as if the call is initiated from an
  end-user, and if so, which user. Additionally, such a scope can carry fields
  such as "super user" or other privileges for use as authorization, or to
  ensure specific code paths can only be access for a given scope.

  It is useful for logging as well as for scoping pubsub subscriptions and
  broadcasts when a caller subscribes to an interface or performs a particular
  action.

  Feel free to extend the fields on this struct to fit the needs of
  growing application requirements.

  ## Alcance de datos (Fase 1, 2026-08-11 — corregido en Fase 3)

  `branches_permitidos`/`sales_units_permitidas`/`inventory_locations_permitidas`
  son la base del modelo de Alcance de Datos (jerarquía Empresa -> Branch ->
  {SalesUnit, InventoryLocation}, ver
  `MetadataApp.Autenticacion.{Branch,SalesUnit,InventoryLocation}`) — QUÉ
  ids puede ver/operar el usuario en cada dimensión, ortogonal al RBAC de
  `MetadataApp.Permissions` (que resuelve QUÉ ACCIONES puede hacer). Estas
  3 listas SÍ son fijas por sesión (la asignación del usuario no cambia
  según qué catálogo esté mirando), por eso viven acá, hidratadas una vez
  por request/mount (ver `UsuarioAuth.hidratar_alcance/1`).

  **Lo que NO vive acá, a propósito**: un `alcance_tipo` único de sesión
  (existió en la Fase 1 original, se sacó en la Fase 3) — un mismo usuario
  puede necesitar `:propio` en el catálogo "Ventas" y `:empresa` en
  "Reportes", así que el tipo efectivo NO es un valor fijo del Scope, es
  una función de (rol, catálogo) resuelta en runtime — ver
  `MetadataApp.Permissions.alcance_tipo_efectivo/2`, mismo criterio de
  granularidad que ya usa `RolPermiso` (permisos por catálogo, no
  globales).

  El sentinel `:sistema` (ver `t_ou_sistema/0`) reemplaza a un `Scope` real
  en llamadas internas sin usuario humano (reglas post, Oban, seeds,
  mix tasks) — nunca confundible por accidente con un `%Scope{}`, ver Fase 4a/4b.

  ## Jerarquía operativa activa (2026-08-11, extensión sobre el modelo de Alcance de Datos)

  `branch_activo`/`inventory_location_activo`/`sales_unit_activo` son
  DISTINTOS de `branches_permitidos`/`sales_units_permitidas`/
  `inventory_locations_permitidas` de arriba — esas 3 listas son "QUÉ
  puede ver/operar" (el universo permitido), estos 3 campos son "CON QUÉ
  está operando AHORA" (uno solo, elegido de ese universo, mismo criterio
  que ya usa `empresa_activa` con `empresas_de_usuario/1`). Se usan para
  autocompletar `branch_id`/`inventory_id`/`sales_unit_id` al crear un
  registro en un catálogo con alcance habilitado, cuando el formulario no
  trae un valor explícito (ver `UsuarioAuth.log_in_usuario/2` para el
  criterio de selección al login, mismo patrón que ya usa empresa: 0
  permitidos no pide nada, 1 solo se autoactiva, 2+ obliga a elegir).

  `branch_activo`/`inventory_location_activo` son OBLIGATORIOS de tener
  elegidos para operar (mismo criterio que `empresa_activa`) —
  `sales_unit_activo` es el único opcional de los tres, puede quedar
  `nil` aunque el usuario tenga varias Unidades de Venta permitidas.
  """

  alias MetadataApp.Autenticacion.Usuario

  defstruct usuario: nil,
            empresa_activa: nil,
            branches_permitidos: [],
            sales_units_permitidas: [],
            inventory_locations_permitidas: [],
            branch_activo: nil,
            inventory_location_activo: nil,
            sales_unit_activo: nil

  @type t :: %__MODULE__{
          usuario: Usuario.t() | nil,
          empresa_activa: struct() | nil,
          branches_permitidos: [integer()],
          sales_units_permitidas: [integer()],
          inventory_locations_permitidas: [integer()],
          branch_activo: struct() | nil,
          inventory_location_activo: struct() | nil,
          sales_unit_activo: struct() | nil
        }

  @typedoc "Un Scope real, o el sentinel :sistema para código interno sin usuario humano — ver el moduledoc."
  @type t_ou_sistema :: t() | :sistema

  @doc """
  Creates a scope for the given usuario.

  Returns nil if no usuario is given.
  """
  def for_usuario(%Usuario{} = usuario) do
    %__MODULE__{usuario: usuario}
  end

  def for_usuario(nil), do: nil

  @doc "Fija la empresa activa de un scope ya construido (post-login, vía selector)."
  def con_empresa_activa(%__MODULE__{} = scope, empresa) do
    %{scope | empresa_activa: empresa}
  end

  @doc "Fija el branch activo de un scope ya construido (post-login, o cambiado después desde el selector de la banda de pie)."
  def con_branch_activo(%__MODULE__{} = scope, branch) do
    %{scope | branch_activo: branch}
  end

  @doc "Fija el inventory location activo de un scope ya construido (post-login, o cambiado después desde el selector de la banda de pie)."
  def con_inventory_location_activo(%__MODULE__{} = scope, inventory_location) do
    %{scope | inventory_location_activo: inventory_location}
  end

  @doc "Fija el sales unit activo de un scope ya construido — a diferencia de branch/inventory, puede fijarse en nil (es opcional)."
  def con_sales_unit_activo(%__MODULE__{} = scope, sales_unit) do
    %{scope | sales_unit_activo: sales_unit}
  end
end
