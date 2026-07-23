defmodule MetadataApp.MetaStateEngine.ReglaPre do
  @moduledoc """
  Contrato del código PRE de un catálogo (rediseño 2026-07-21) — un solo
  módulo por catálogo (convención: `MetadataApp.MetaBusinessProcess.Reglas.<Catalogo>.Pre`,
  ver `MetadataApp.MetaStateEngine.Reglas.modulo_pre/1`), con un `case`
  interno por `accion` — ya no un módulo por regla individual.

  Para el primer error encontrado, devolver `{:error, mensaje}` — no hay
  colección de múltiples errores (decisión explícita: más simple que el
  viejo mecanismo de varias filas sin cortocircuito).

  `{:error, :sin_permiso, mensaje}` es un caso especial (agregado
  2026-07-23, restaurado tras el rediseño de reglas del 07-21 que lo había
  perdido): a diferencia de cualquier otro rechazo, que deja la transición
  visible pero deshabilitada, este la OCULTA por completo del
  descubrimiento (`MetaStateEngine.transiciones_disponibles/2`) — no
  revela ni que la acción existe a quien no tiene permiso. La regla
  built-in `requiere_rol` ya lo usa (vía `MetadataApp.MetaPermissions.can?/3`,
  el único punto de integración pensado para reemplazarse por RBAC real
  más adelante). Una regla de negocio propia puede usarlo igual para
  cualquier otro chequeo de "no debería ni saber que esto existe".

  Nunca debe actualizar datos — solo lectura. Para consultar OTRO catálogo
  (no el propio), usar `MetadataApp.MetaBcCliente`, nunca
  `CatalogoGenerico`/`MetaStateEngine` directamente.
  """

  @callback evaluar(accion :: String.t(), registro :: struct(), contexto :: map()) ::
              :ok | {:error, String.t()} | {:error, :sin_permiso, String.t()}
end
