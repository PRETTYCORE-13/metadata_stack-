defmodule MetadataApp.MetaBcApi do
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
        # :sistema (Fase 4a del modelo de Alcance de Datos) -- código de
        # negocio interno, sin usuario humano detrás; mismo criterio que
        # el resto de este módulo (acceso cross-catálogo sin RBAC,
        # responsabilidad de quien escribe la regla).
        {:ok, CatalogoGenerico.obtener!(modulo, :sistema, id)}
      rescue
        Ecto.NoResultsError -> {:error, :no_encontrado}
      end
    end
  end

  @doc "Lectura con filtros (`%{\"campo\" => valor}`, AND) — permitido desde PRE y POST."
  @spec listar(String.t(), map()) :: {:ok, [struct()]} | {:error, :no_encontrado}
  def listar(tabla, filtros \\ %{}) do
    with {:ok, modulo} <- resolver(tabla) do
      {:ok, CatalogoGenerico.listar(modulo, :sistema, filtros)}
    end
  end

  @doc """
  Ejecuta un Servicio (Consulta SQL de uso "servicio", SPEC-SYS-2509202601
  §11.5) por su nombre — lectura, permitido desde PRE y POST. Corre como
  `:sistema`, igual que el resto de este módulo (R44). Dentro de una
  transición ve los cambios todavía no confirmados de esa misma
  transacción (R47) y un error nunca la aborta (R46).

      MetaBcApi.ejecutar_servicio("pty_sql_materiales_precio_venta",
        %{"direccion_id" => 1, "productos" => [101, 102]})

  `{:ok, %{columnas: [texto], filas: [%{texto => valor}]}}` o
  `{:error, :tiempo_excedido | mensaje}` (por ejemplo, "No existe el
  servicio ... en este ambiente.", R48).
  """
  @spec ejecutar_servicio(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def ejecutar_servicio(nombre, valores) when is_binary(nombre) and is_map(valores) do
    MetadataApp.ConsultasSql.ejecutar_servicio(nombre, valores, :sistema)
  end

  @doc "Alta en otro catálogo — solo permitido desde reglas POST."
  @spec crear(String.t(), map()) :: {:ok, struct()} | {:error, term()}
  def crear(tabla, attrs) do
    # :sistema (Fase 4b) -- mismo criterio que obtener/2 y listar/2 arriba.
    with {:ok, modulo} <- resolver(tabla), do: CatalogoGenerico.crear(modulo, :sistema, attrs)
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
