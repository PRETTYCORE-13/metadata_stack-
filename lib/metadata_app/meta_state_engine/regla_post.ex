defmodule MetadataApp.MetaStateEngine.ReglaPost do
  @moduledoc """
  Contrato del código POST de un catálogo (rediseño 2026-07-21) — un solo
  módulo por catálogo (convención: `MetadataApp.MetaBusinessProcess.Reglas.<Catalogo>.Post`,
  ver `MetadataApp.MetaStateEngine.Reglas.modulo_post/1`), con un `case`
  interno por `accion`.

  Corre SIEMPRE dentro de la transacción de la transición (mismo
  comportamiento que antes tenía `transaccional: true`) — si devuelve
  `{:error, _}`, todo se revierte. Ya no existe el flag `transaccional:
  false` de antes ("efecto de cortesía" async después del commit) — si
  hace falta ese comportamiento para algo puntual (ej. mandar un email sin
  bloquear la transición), escribirlo a mano dentro del código con
  `Task.Supervisor.start_child(MetadataApp.MetaStateEngine.TaskSupervisor, fn -> ... end)`
  — no es responsabilidad del motor.

  Puede crear/actualizar/borrar datos — del propio registro o, vía
  `MetadataApp.MetaBcCliente`, de otros catálogos (nunca tocando
  `CatalogoGenerico`/`MetaStateEngine` de otro catálogo directamente).
  """

  @callback ejecutar(accion :: String.t(), registro :: struct(), contexto :: map(), repo :: module()) ::
              {:ok, term()} | {:error, term()}
end
