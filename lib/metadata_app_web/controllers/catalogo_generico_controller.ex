defmodule MetadataAppWeb.CatalogoGenericoController do
  defmacro __using__(opts) do
    schema_mod = Keyword.fetch!(opts, :schema)
    param_key = Keyword.get(opts, :param, "data")

    quote do
      use MetadataAppWeb, :controller
      alias MetadataApp.CatalogoGenerico
      alias MetadataApp.MetaModelContext

      action_fallback MetadataAppWeb.FallbackController

      @schema_mod unquote(schema_mod)
      @param_key unquote(param_key)

      def index(conn, _params) do
        items = CatalogoGenerico.listar(@schema_mod)
        meta_campos = @param_key |> MetaModelContext.listar_campos() |> Enum.map(&MetaModelContext.serializar_campo/1)

        json(
          conn,
          Jason.OrderedObject.new(
            meta_campos: meta_campos,
            data: Enum.map(items, &CatalogoGenerico.serializar/1)
          )
        )
      end

      def show(conn, %{"id" => id}) do
        item = CatalogoGenerico.obtener!(@schema_mod, id)
        meta_campos = @param_key |> MetaModelContext.listar_campos() |> Enum.map(&MetaModelContext.serializar_campo/1)

        json(
          conn,
          Jason.OrderedObject.new(meta_campos: meta_campos, data: CatalogoGenerico.serializar(item))
        )
      end

      def create(conn, params) do
        attrs = Map.get(params, @param_key, params)

        with {:ok, item} <- CatalogoGenerico.crear(@schema_mod, attrs) do
          conn
          |> put_status(:created)
          |> json(%{data: CatalogoGenerico.serializar(item)})
        end
      end

      def update(conn, %{"id" => id} = params) do
        attrs = Map.get(params, @param_key, params)
        item = CatalogoGenerico.obtener!(@schema_mod, id)

        with {:ok, item} <- CatalogoGenerico.actualizar(item, attrs) do
          json(conn, %{data: CatalogoGenerico.serializar(item)})
        end
      end

      def delete(conn, %{"id" => id}) do
        item = CatalogoGenerico.obtener!(@schema_mod, id)

        with {:ok, _item} <- CatalogoGenerico.eliminar(item) do
          send_resp(conn, :no_content, "")
        end
      end
    end
  end
end
