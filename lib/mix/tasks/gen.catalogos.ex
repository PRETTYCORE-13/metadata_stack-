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
        |> Enum.map(& &1.schema_context_name)
        |> MetaSchemaContext.ordenar_por_dependencias()
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
end
