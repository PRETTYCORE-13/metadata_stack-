defmodule Mix.Tasks.Meta.Import do
  use Mix.Task
  alias MetadataApp.MetaSchemaContext

  @shortdoc "Importa Business Contexts desde un JSON exportado con mix meta.export"

  @moduledoc """
  Uso: mix meta.import [ruta_entrada]

  Default: priv/repo/metadata_export.json

  Crea el Header + Detalles de cada Business Context descripto en el JSON.
  Si un `schema_context_name` ya existe en la base, se deja sin tocar (no
  actualiza, no duplica). Es el paso previo a `mix gen.catalogos`: deja la
  metadata cargada para que el generador pueda materializar los catálogos.
  """

  def run(args) do
    Mix.Task.run("app.config")

    path = List.first(args) || "priv/repo/metadata_export.json"
    %{"business_contexts" => contextos} = path |> File.read!() |> Jason.decode!()

    {:ok, _resultado, _apps} =
      Ecto.Migrator.with_repo(MetadataApp.Repo, fn _repo ->
        Enum.each(contextos, &importar_uno/1)
      end)
  end

  defp importar_uno(contexto) do
    nombre = contexto["schema_context_name"]

    case MetaSchemaContext.obtener_header_por_nombre(nombre) do
      nil ->
        case MetaSchemaContext.crear_header_con_detalles(contexto) do
          {:ok, {_header, _detalles}} ->
            Mix.shell().info("+ #{nombre}: creado")

          {:error, motivo} ->
            Mix.raise("Error importando #{nombre}: #{inspect(motivo)}")
        end

      _existente ->
        Mix.shell().info("= #{nombre}: ya existía, sin cambios")
    end
  end
end
