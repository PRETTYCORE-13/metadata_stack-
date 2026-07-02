defmodule Mix.Tasks.Gen.Catalogo do
  use Mix.Task

  @shortdoc "Genera migración, schema, controller y ruta de un catálogo a partir de meta_schema"

  @moduledoc """
  Uso: mix gen.catalogo <schema_nombre> <tabla>

  Normalmente no hace falta correrlo a mano: el POST batch a /api/meta_model
  ya dispara esta misma generación automáticamente. Este task queda para
  generar (o regenerar) un catálogo manualmente si hace falta.
  """

  def run([schema_nombre, tabla]) do
    Mix.Task.run("app.config")

    {:ok, resultado, _apps} =
      Ecto.Migrator.with_repo(MetadataApp.Repo, fn _repo ->
        MetadataApp.CatalogoGenerador.generar(schema_nombre, tabla)
      end)

    case resultado do
      {:ok, %{tabla: tabla, ya_existia: true}} ->
        Mix.shell().info("El catálogo #{schema_nombre} ya existía (lib/metadata_app/catalogos/#{schema_nombre}.ex). No se tocó nada. Ruta: /api/#{tabla}")

      {:ok, %{tabla: tabla}} ->
        Mix.shell().info("Catálogo #{schema_nombre} generado y migrado. Ruta: /api/#{tabla}")

      {:error, mensaje} ->
        Mix.raise(mensaje)
    end
  end

  def run(_args) do
    Mix.raise("Uso: mix gen.catalogo <schema_nombre> <tabla>  (ej. mix gen.catalogo talla tallas)")
  end
end
