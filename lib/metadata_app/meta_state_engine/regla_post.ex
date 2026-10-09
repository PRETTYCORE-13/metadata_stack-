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
  `MetadataApp.MetaBcApi`, de otros catálogos (nunca tocando
  `CatalogoGenerico`/`MetaStateEngine` de otro catálogo directamente).
  """

  @callback ejecutar(accion :: String.t(), registro :: struct(), contexto :: map(), repo :: module()) ::
              {:ok, term()} | {:error, term()}

  @doc """
  Opcional (SPEC-SYS-0810202603): cálculo preliminar de un renglón mientras
  se captura en la Ficha. `detalle` es el catálogo del renglón; `encabezado`
  y `renglon` son mapas con llaves de texto y valores como vienen de la
  pantalla (texto) o de la base. Solo lectura: nunca escribe.

  Regresa los valores de las columnas de solo lectura del renglón (los
  demás campos se ignoran), `:sin_calculo` si todavía faltan datos, o
  `{:aviso, texto}` para avisar sin bloquear la captura.
  """
  @callback calcular_renglon(detalle :: String.t(), encabezado :: map(), renglon :: map()) ::
              {:ok, map()} | :sin_calculo | {:aviso, String.t()}

  @optional_callbacks calcular_renglon: 3
end
