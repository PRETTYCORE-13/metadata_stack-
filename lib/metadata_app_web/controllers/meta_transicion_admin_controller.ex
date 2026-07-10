defmodule MetadataAppWeb.MetaTransicionAdminController do
  @moduledoc """
  CRUD admin de `meta_schema_transiciones` (define el grafo: qué acción
  mueve de qué estado a qué estado). Ejecutar una transición sobre un
  registro real es responsabilidad de `MetadataAppWeb.MetaTransicionController`.
  """

  use MetadataAppWeb, :controller

  alias MetadataApp.MetaEstadosAdmin

  action_fallback MetadataAppWeb.FallbackController

  def index(conn, %{"meta_schema_header_id" => header_id}) do
    data = header_id |> MetaEstadosAdmin.listar_transiciones() |> Enum.map(&transicion_data/1)
    json(conn, %{data: data})
  end

  def create(conn, %{"meta_schema_transicion" => attrs}) when is_list(attrs) do
    with {:ok, transiciones} <- MetaEstadosAdmin.crear_transiciones(attrs) do
      conn
      |> put_status(:created)
      |> json(%{data: Enum.map(transiciones, &transicion_data/1)})
    end
  end

  def create(conn, %{"meta_schema_transicion" => attrs}) do
    with {:ok, transicion} <- MetaEstadosAdmin.crear_transicion(attrs) do
      conn
      |> put_status(:created)
      |> json(%{data: transicion_data(transicion)})
    end
  end

  defp transicion_data(t) do
    %{
      id: t.id,
      meta_schema_header_id: t.meta_schema_header_id,
      accion: t.accion,
      etiqueta: t.etiqueta,
      estado_origen_id: t.estado_origen_id,
      estado_destino_id: t.estado_destino_id,
      reglas: reglas_data(t)
    }
  end

  defp reglas_data(%{reglas: reglas}) when is_list(reglas) do
    Enum.map(reglas, fn r ->
      %{id: r.id, tipo: r.tipo, regla: r.regla, params: r.params, orden: r.orden, transaccional: r.transaccional}
    end)
  end

  defp reglas_data(_), do: []
end
