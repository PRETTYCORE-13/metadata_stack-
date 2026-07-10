defmodule Mix.Tasks.Gen.Catalogos do
  use Mix.Task
  alias MetadataApp.BusinessProcessBuilder.{MetaSchemaContext, CatalogoGenerador}

  @shortdoc "Genera todos los catálogos pendientes a partir de la metadata"

  @moduledoc """
  Uso: mix gen.catalogos

  Recorre todos los Business Context de meta_schema_header y genera
  (migración + schema Ecto) cada uno que todavía no tenga su archivo en
  lib/metadata_app/meta_business_process/catalogos/, respetando el orden de dependencias de los
  campos tipo "referencia": un catálogo se genera después de todos los que
  referencia, porque su migración crea una FK contra una tabla que tiene que
  existir primero en Postgres. Sin este orden, `CatalogoGenerador` podría
  escribir la migración de un catálogo dependiente antes que la del catálogo
  referenciado, y esa migración fallaría al correr contra una tabla
  inexistente.

  Reemplaza correr `mix gen.catalogo <nombre>` uno por uno.
  """

  def run(_args) do
    Mix.Task.run("app.config")

    {:ok, resultados, _apps} =
      Ecto.Migrator.with_repo(MetadataApp.Repo, fn _repo ->
        MetaSchemaContext.listar_headers()
        |> ordenar_por_dependencias()
        |> Enum.map(fn nombre -> {nombre, CatalogoGenerador.generar(nombre)} end)
      end)

    Enum.each(resultados, &reportar/1)
  end

  defp reportar({nombre, {:ok, %{ya_existia: true}}}),
    do: Mix.shell().info("= #{nombre}: ya existía, sin cambios")

  defp reportar({nombre, {:ok, %{ya_existia: false}}}),
    do: Mix.shell().info("+ #{nombre}: generado y migrado")

  defp reportar({nombre, {:error, motivo}}),
    do: Mix.shell().error("x #{nombre}: #{motivo}")

  # Orden topológico (Kahn) sobre la relación "campo tipo referencia -> catalogo".
  # Si queda un ciclo sin poder resolverse dentro del lote, se aborta con
  # error en vez de generar en un orden que rompería las migraciones.
  defp ordenar_por_dependencias(headers) do
    nombres = headers |> Enum.map(& &1.schema_context_name) |> MapSet.new()

    dependencias =
      Map.new(headers, fn header ->
        deps =
          header.schema_context_name
          |> MetaSchemaContext.listar_detalles()
          |> Enum.filter(&(Map.get(&1.schema_context_properties || %{}, "tipo") == "referencia"))
          |> Enum.map(&Map.fetch!(&1.schema_context_properties, "catalogo"))
          |> Enum.filter(&MapSet.member?(nombres, &1))
          |> Enum.uniq()

        {header.schema_context_name, deps}
      end)

    ordenar(dependencias, [])
  end

  defp ordenar(pendientes, hechos) when map_size(pendientes) == 0, do: Enum.reverse(hechos)

  defp ordenar(pendientes, hechos) do
    hechos_set = MapSet.new(hechos)

    {listos, resto} =
      Enum.split_with(pendientes, fn {_nombre, deps} ->
        Enum.all?(deps, &MapSet.member?(hechos_set, &1))
      end)

    case listos do
      [] ->
        Mix.raise(
          "Dependencia circular entre catálogos, no se puede determinar un orden: #{inspect(Map.keys(pendientes))}"
        )

      _ ->
        nombres_listos = Enum.map(listos, fn {nombre, _deps} -> nombre end)
        ordenar(Map.new(resto), Enum.reverse(nombres_listos) ++ hechos)
    end
  end
end
