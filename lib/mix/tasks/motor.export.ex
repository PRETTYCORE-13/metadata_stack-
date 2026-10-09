defmodule Mix.Tasks.Motor.Export do
  use Mix.Task
  alias MetadataApp.BusinessProcessBuilder.MetaSchemaContext
  alias MetadataApp.MetaEstadosAdmin

  @shortdoc "Exporta el autómata (estados/transiciones/reglas) a un archivo JSON por catálogo"

  @moduledoc """
  Uso: mix motor.export [directorio_salida]

  Default: priv/repo/catalogos/ (mismo directorio que `mix meta.export`,
  sufijo distinto: `<catalogo>.motor.json`)

  Vuelca el autómata (estados/transiciones/reglas) de cada Business
  Context que lo adoptó — un archivo por catálogo, mismo motivo que
  `mix meta.export`: con muchos catálogos, un solo `motor_export.json`
  hacía que publicar UNO tocara el diff/merge de TODOS. Resuelve toda
  referencia cruzada por NOMBRE, no por id, porque los ids
  autoincrementales no coinciden entre bases distintas.

  Los `.motor.json` huérfanos (catálogos sin autómata o que no existen en
  la base local) se listan y solo se borran si se confirma
  (`Mix.Tasks.Meta.Huerfanos`, SPEC-SYS-0210202601 R6).
  """

  def run(args) do
    Mix.Task.run("app.config")

    dir = List.first(args) || "priv/repo/catalogos"
    File.mkdir_p!(dir)

    {:ok, nombres, _apps} =
      Ecto.Migrator.with_repo(MetadataApp.Repo, fn _repo ->
        MetaSchemaContext.listar_headers()
        |> Enum.map(&MetaEstadosAdmin.exportar_header(&1, dir))
        |> Enum.reject(&is_nil/1)
      end)

    Mix.Tasks.Meta.Huerfanos.limpiar(dir, nombres, ".motor.json")
    Mix.shell().info("Exportado el autómata de #{length(nombres)} catálogo(s) a #{dir}/")
  end
end
