defmodule Mix.Tasks.Plantillas.Export do
  use Mix.Task
  alias MetadataApp.BusinessProcessBuilder.MetaSchemaContext
  alias MetadataApp.MetaPlantillas

  @shortdoc "Exporta las plantillas del Constructor (Formulario: Vistas + Impresión) a un archivo JSON por catálogo"

  @moduledoc """
  Uso: mix plantillas.export [directorio_salida]

  Default: priv/repo/catalogos/ (mismo directorio que `mix meta.export`/
  `mix motor.export`, sufijo distinto: `<catalogo>.plantillas.json`)

  Vuelca TODAS las plantillas (Vista + Impresión, borrador y publicada) de
  cada Business Context que tenga alguna — un archivo por catálogo, mismo
  motivo que `mix meta.export`: con muchos catálogos, un dump único hacía
  que publicar UNO tocara el diff de TODOS. Resuelve el catálogo por
  NOMBRE, no por id.

  Los `.plantillas.json` huérfanos (catálogos sin plantillas o que no
  existen en la base local) se listan y solo se borran si se confirma
  (`Mix.Tasks.Meta.Huerfanos`, SPEC-SYS-0210202601 R6).
  """

  def run(args) do
    Mix.Task.run("app.config")

    dir = List.first(args) || "priv/repo/catalogos"
    File.mkdir_p!(dir)

    {:ok, nombres, _apps} =
      Ecto.Migrator.with_repo(MetadataApp.Repo, fn _repo ->
        MetaSchemaContext.listar_headers()
        |> Enum.map(&MetaPlantillas.exportar_header(&1, dir))
        |> Enum.reject(&is_nil/1)
      end)

    Mix.Tasks.Meta.Huerfanos.limpiar(dir, nombres, ".plantillas.json")
    Mix.shell().info("Exportadas las plantillas de #{length(nombres)} catálogo(s) a #{dir}/")
  end
end
