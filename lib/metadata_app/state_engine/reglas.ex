defmodule MetadataApp.StateEngine.Reglas do
  @moduledoc """
  Vocabulario de reglas del Motor de Estados: despacho por nombre de regla.

  Las 8 reglas genéricas (sección 5 del spec) viven en `Reglas.Pre` /
  `Reglas.Post`, compartidas por cualquier catálogo. Un nombre que NO está
  en ese vocabulario cerrado se resuelve por CONVENCIÓN DE NOMBRES a un
  módulo de negocio escrito fuera del motor — `NegocioReglas.<Catalogo>.
  <Regla>`, implementando `StateEngine.ReglaPre`/`ReglaPost` — sin que el
  motor necesite ninguna tabla/config compartida donde "registrarlo".
  Cada catálogo es dueño de su propio namespace, no hay coordinación entre
  equipos ni cambios acá para agregar una regla nueva.

  `prueba_ok`/`prueba_falla` son fixtures de la Fase 2 para testear el
  ciclo (`MetadataApp.StateEngine`) en aislamiento — no son vocabulario de
  negocio, no confundir con las reglas reales.
  """

  alias MetadataApp.StateEngine.Reglas.{Pre, Post}

  @vocabulario_pre ~w(campos_requeridos campo_cumple sin_relacionados requiere_rol dato_en_contexto)
  @vocabulario_post ~w(estampar_valor mutar_relacionados notificar)

  @doc "Precondición: (nombre, registro, contexto, params) -> :ok | {:error, mensaje}. Solo lectura."
  def evaluar_precondicion("prueba_ok", _registro, _contexto, _params), do: :ok

  def evaluar_precondicion("prueba_falla", _registro, _contexto, params),
    do: {:error, Map.get(params, "mensaje", "regla de prueba: siempre falla")}

  def evaluar_precondicion(nombre, registro, contexto, params) when nombre in @vocabulario_pre,
    do: Pre.evaluar(nombre, registro, contexto, params)

  def evaluar_precondicion(nombre, registro, contexto, params) do
    with {:ok, modulo} <- resolver_negocio(registro, nombre, :evaluar, 3) do
      modulo.evaluar(registro, contexto, params)
    end
  end

  @doc "Postcondición: (nombre, registro, contexto, params, repo) -> {:ok, cambios} | {:error, razon}."
  def ejecutar_postcondicion("prueba_ok", _registro, _contexto, _params, _repo),
    do: {:ok, :prueba_ok}

  def ejecutar_postcondicion("prueba_falla", _registro, _contexto, params, _repo),
    do: {:error, Map.get(params, "mensaje", "regla de prueba: siempre falla")}

  def ejecutar_postcondicion(nombre, registro, contexto, params, repo) when nombre in @vocabulario_post,
    do: Post.ejecutar(nombre, registro, contexto, params, repo)

  def ejecutar_postcondicion(nombre, registro, contexto, params, repo) do
    with {:ok, modulo} <- resolver_negocio(registro, nombre, :ejecutar, 4) do
      modulo.ejecutar(registro, contexto, params, repo)
    end
  end

  @doc """
  Nombre del módulo de negocio esperado para `nombre_regla` en `catalogo`,
  por convención `NegocioReglas.<Catalogo>.<Regla>` — pura construcción de
  nombre, no valida que exista ni que implemente nada (usado también por
  `MetadataApp.MotorEstadosAdmin.validar_motor/1`).
  """
  @spec modulo_negocio(String.t(), String.t()) :: module()
  def modulo_negocio(catalogo, nombre_regla) do
    Module.concat([NegocioReglas, Macro.camelize(catalogo), Macro.camelize(nombre_regla)])
  end

  defp resolver_negocio(registro, nombre_regla, funcion, aridad) do
    catalogo = registro.__struct__.__schema__(:source)
    modulo = modulo_negocio(catalogo, nombre_regla)

    cond do
      not Code.ensure_loaded?(modulo) ->
        {:error,
         "regla \"#{nombre_regla}\" no existe ni en el vocabulario del motor ni como módulo de negocio (se esperaba #{inspect(modulo)})"}

      not function_exported?(modulo, funcion, aridad) ->
        {:error, "el módulo #{inspect(modulo)} existe pero no implementa #{funcion}/#{aridad}"}

      true ->
        {:ok, modulo}
    end
  end
end
