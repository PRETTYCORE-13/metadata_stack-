defmodule Mix.Tasks.Meta.Export do
  use Mix.Task
  alias MetadataApp.BusinessProcessBuilder.MetaSchemaContext

  @shortdoc "Exporta meta_schema_header + meta_schema_detail a un JSON versionable"

  @moduledoc """
  Uso: mix meta.export [ruta_salida]

  Default: priv/repo/metadata_export.json

  Vuelca todos los Business Context activos (headers no borrados) con sus
  detalles a un archivo JSON. Es la fuente de verdad portable para
  reconstruir los catálogos en cualquier entorno vía `mix meta.import` +
  `mix gen.catalogos`, sin depender de una conexión viva a la base de origen.
  """

  def run(args) do
    Mix.Task.run("app.config")

    path = List.first(args) || "priv/repo/metadata_export.json"

    {:ok, {contenido, total}, _apps} =
      Ecto.Migrator.with_repo(MetadataApp.Repo, fn _repo ->
        business_contexts =
          MetaSchemaContext.listar_headers()
          |> Enum.map(fn header ->
            detalles = MetaSchemaContext.listar_detalles(header.schema_context_name)

            %{
              schema_context_name: header.schema_context_name,
              schema_context_label: header.schema_context_label,
              schema_context_type: header.schema_context_type,
              schema_context_nav: header.schema_context_nav,
              schema_visible: header.schema_visible,
              schema_set_permissions: header.schema_set_permissions,
              schema_profiles: header.schema_profiles,
              detalles: Enum.map(detalles, &MetaSchemaContext.serializar_detalle/1)
            }
          end)

        contenido = Jason.encode!(%{business_contexts: business_contexts}, pretty: true)
        {contenido, length(business_contexts)}
      end)

    File.write!(path, contenido)
    Mix.shell().info("Exportados #{total} Business Context(s) a #{path}")
  end
end
