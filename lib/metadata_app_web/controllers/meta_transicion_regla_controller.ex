defmodule MetadataAppWeb.MetaTransicionReglaController do
  @moduledoc """
  CRUD admin de `meta_schema_transicion_reglas` — las pre/postcondiciones de
  una transición ya creada (vocabulario cerrado de 8 reglas, ver
  `MetadataApp.MetaStateEngine.Reglas`).
  """

  use MetadataAppWeb, :controller

  alias MetadataApp.MetaEstadosAdmin

  action_fallback MetadataAppWeb.FallbackController

  def index(conn, %{"transicion_id" => transicion_id}) do
    data = transicion_id |> MetaEstadosAdmin.listar_reglas() |> Enum.map(&regla_data/1)
    json(conn, %{data: data})
  end

  def create(conn, %{"meta_schema_transicion_regla" => attrs}) when is_list(attrs) do
    with {:ok, reglas} <- MetaEstadosAdmin.crear_reglas(attrs) do
      conn
      |> put_status(:created)
      |> json(%{data: Enum.map(reglas, &regla_data/1)})
    end
  end

  def create(conn, %{"meta_schema_transicion_regla" => attrs}) do
    with {:ok, regla} <- MetaEstadosAdmin.crear_regla(attrs) do
      conn
      |> put_status(:created)
      |> json(%{data: regla_data(regla)})
    end
  end

  defp regla_data(r) do
    %{
      id: r.id,
      transicion_id: r.transicion_id,
      tipo: r.tipo,
      regla: r.regla,
      params: r.params,
      orden: r.orden,
      transaccional: r.transaccional
    }
  end
end
