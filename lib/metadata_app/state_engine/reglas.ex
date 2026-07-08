defmodule MetadataApp.StateEngine.Reglas do
  @moduledoc """
  Vocabulario de reglas del Motor de Estados: despacho por pattern matching
  sobre el nombre de la regla. Catálogo cerrado — nunca código/scripts libres
  configurados por el usuario.

  Las reglas de negocio reales viven en `Reglas.Pre` / `Reglas.Post` (las 8
  de la sección 5 del spec). `prueba_ok`/`prueba_falla` son fixtures de la
  Fase 2 para testear el ciclo (`MetadataApp.StateEngine`) en aislamiento —
  no son vocabulario de negocio, no confundir con las reglas reales.
  """

  alias MetadataApp.StateEngine.Reglas.{Pre, Post}

  @doc "Precondición: (nombre, registro, contexto, params) -> :ok | {:error, mensaje}. Solo lectura."
  def evaluar_precondicion("prueba_ok", _registro, _contexto, _params), do: :ok

  def evaluar_precondicion("prueba_falla", _registro, _contexto, params),
    do: {:error, Map.get(params, "mensaje", "regla de prueba: siempre falla")}

  def evaluar_precondicion(nombre, registro, contexto, params),
    do: Pre.evaluar(nombre, registro, contexto, params)

  @doc "Postcondición: (nombre, registro, contexto, params, repo) -> {:ok, cambios} | {:error, razon}."
  def ejecutar_postcondicion("prueba_ok", _registro, _contexto, _params, _repo),
    do: {:ok, :prueba_ok}

  def ejecutar_postcondicion("prueba_falla", _registro, _contexto, params, _repo),
    do: {:error, Map.get(params, "mensaje", "regla de prueba: siempre falla")}

  def ejecutar_postcondicion(nombre, registro, contexto, params, repo),
    do: Post.ejecutar(nombre, registro, contexto, params, repo)
end
