defmodule MetadataApp.MetaStateEngine.ReglaPre do
  @moduledoc """
  Contrato del código PRE de un catálogo (rediseño 2026-07-21) — un solo
  módulo por catálogo (convención: `MetadataApp.MetaBusinessProcess.Reglas.<Catalogo>.Pre`,
  ver `MetadataApp.MetaStateEngine.Reglas.modulo_pre/1`), con un `case`
  interno por `accion` — ya no un módulo por regla individual.

  Para el primer error encontrado, devolver `{:error, mensaje}` — no hay
  colección de múltiples errores (decisión explícita: más simple que el
  viejo mecanismo de varias filas sin cortocircuito).

  Nunca debe actualizar datos — solo lectura. Para consultar OTRO catálogo
  (no el propio), usar `MetadataApp.MetaBcCliente`, nunca
  `CatalogoGenerico`/`MetaStateEngine` directamente.
  """

  @callback evaluar(accion :: String.t(), registro :: struct(), contexto :: map()) ::
              :ok | {:error, String.t()}
end
