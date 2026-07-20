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

  Sincroniza el directorio: catálogos sin autómata (o borrados) no dejan
  un `.motor.json` huérfano.
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

    limpiar_huerfanos(dir, nombres, ".motor.json")
    Mix.shell().info("Exportado el autómata de #{length(nombres)} catálogo(s) a #{dir}/")
  end

  defp limpiar_huerfanos(dir, nombres_vigentes, sufijo) do
    esperados = MapSet.new(nombres_vigentes, &"#{&1}#{sufijo}")

    dir
    |> File.ls!()
    |> Enum.filter(&String.ends_with?(&1, sufijo))
    |> Enum.reject(&MapSet.member?(esperados, &1))
    |> Enum.each(fn archivo ->
      File.rm!(Path.join(dir, archivo))
      Mix.shell().info("  (huérfano borrado: #{archivo})")
    end)
  end
end
