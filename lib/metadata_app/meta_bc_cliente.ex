defmodule MetadataApp.MetaBcCliente do
  @moduledoc """
  Única puerta de entrada para que una regla de negocio (`MetaStateEngine.
  ReglaPre`/`ReglaPost`) interactúe con OTRO Business Context. Una regla
  nunca debe importar `BusinessProcessBuilder.CatalogoGenerico`/`MetaStateEngine`/`BusinessProcessBuilder.MetaSchemaContext`
  directamente — siempre pasar por acá, por nombre de catálogo (el mismo
  string que ya se usa en `/api/:tabla`), nunca por módulo Ecto.

  Es una llamada de función interna, no HTTP real: mientras se está
  adentro de una transición (`Repo.transaction`), Ecto asocia cualquier
  query al mismo proceso/conexión — así una regla POST que crea o
  transiciona datos en otro catálogo queda atómica junto con el resto del
  ciclo si la regla es `transaccional: true`, sin que la regla tenga que
  manejar la transacción a mano.
  """

  alias MetadataApp.BusinessProcessBuilder.{CatalogoGenerico, MetaSchemaContext}
  alias MetadataApp.MetaStateEngine

  @doc "Lectura — permitido desde reglas PRE y POST."
  @spec obtener(String.t(), integer()) :: {:ok, struct()} | {:error, :no_encontrado}
  def obtener(tabla, id) do
    with {:ok, modulo} <- resolver(tabla) do
      try do
        {:ok, CatalogoGenerico.obtener!(modulo, id)}
      rescue
        Ecto.NoResultsError -> {:error, :no_encontrado}
      end
    end
  end

  @doc "Lectura con filtros (`%{\"campo\" => valor}`, AND) — permitido desde PRE y POST."
  @spec listar(String.t(), map()) :: {:ok, [struct()]} | {:error, :no_encontrado}
  def listar(tabla, filtros \\ %{}) do
    with {:ok, modulo} <- resolver(tabla) do
      {:ok, CatalogoGenerico.listar(modulo, filtros)}
    end
  end

  @doc "Alta en otro catálogo — solo permitido desde reglas POST."
  @spec crear(String.t(), map()) :: {:ok, struct()} | {:error, term()}
  def crear(tabla, attrs) do
    with {:ok, modulo} <- resolver(tabla), do: CatalogoGenerico.crear(modulo, attrs)
  end

  @doc "Baja en otro catálogo — solo permitido desde reglas POST."
  @spec eliminar(String.t(), integer()) :: {:ok, struct()} | {:error, term()}
  def eliminar(tabla, id) do
    with {:ok, registro} <- obtener(tabla, id), do: CatalogoGenerico.eliminar(registro)
  end

  @doc """
  Ejecuta una transición sobre un registro de OTRO catálogo — solo
  permitido desde reglas POST. Corre con las reglas propias de ese
  catálogo (nunca se saltean); si ese catálogo rechaza la transición, esta
  llamada devuelve el mismo error estructurado que `MetaStateEngine.
  ejecutar_transicion/3`.
  """
  @spec ejecutar_transicion(String.t(), integer(), String.t(), map()) ::
          {:ok, struct()} | {:error, term()}
  def ejecutar_transicion(tabla, id, accion, contexto \\ %{}) do
    with {:ok, registro} <- obtener(tabla, id) do
      MetaStateEngine.ejecutar_transicion(registro, accion, contexto)
    end
  end

  defp resolver(tabla) do
    case MetaSchemaContext.modulo_por_nombre(tabla) do
      nil -> {:error, :no_encontrado}
      modulo -> {:ok, modulo}
    end
  end
end
