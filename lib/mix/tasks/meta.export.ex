defmodule Mix.Tasks.Meta.Export do
  use Mix.Task
  alias MetadataApp.BusinessProcessBuilder.MetaSchemaContext

  @shortdoc "Exporta meta_schema_header + meta_schema_detail a un archivo JSON por catálogo"

  @moduledoc """
  Uso: mix meta.export [directorio_salida]

  Default: priv/repo/catalogos/

  Un archivo `<catalogo>.meta.json` por Business Context activo (headers
  no borrados), con sus detalles. Reemplaza el export anterior de un solo
  `metadata_export.json` con todos los catálogos adentro: con muchos
  catálogos y varios desarrolladores tocando cada uno los suyos, un
  archivo único hacía que cualquier publicación reescribiera — y en el
  diff de git, aparentara tocar — TODOS los catálogos, no solo el que
  cambió.

  Los `.meta.json` de catálogos que no existen en la base local
  (huérfanos) se listan y solo se borran si se confirma
  (`Mix.Tasks.Meta.Huerfanos`, SPEC-SYS-0210202601 R6): la carpeta es
  compartida y pueden ser de otra persona.
  """

  def run(args) do
    Mix.Task.run("app.config")

    dir = List.first(args) || "priv/repo/catalogos"
    File.mkdir_p!(dir)

    {:ok, nombres, _apps} =
      Ecto.Migrator.with_repo(MetadataApp.Repo, fn _repo ->
        MetaSchemaContext.listar_headers()
        |> Enum.map(&MetaSchemaContext.exportar_header(&1, dir))
      end)

    Mix.Tasks.Meta.Huerfanos.limpiar(dir, nombres, ".meta.json")
    Mix.shell().info("Exportados #{length(nombres)} Business Context(s) a #{dir}/")
  end
end
