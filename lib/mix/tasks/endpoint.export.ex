defmodule Mix.Tasks.Endpoint.Export do
  use Mix.Task
  alias MetadataApp.ConsultaEndpoints

  @shortdoc "Exporta la config de cada Endpoint vivo a un archivo JSON por Consulta"

  @moduledoc """
  Uso: mix endpoint.export [directorio_salida]

  Default: priv/repo/catalogos/

  Un archivo `<consulta>.endpoint.json` por cada Endpoint vivo
  (SPEC-SYS-1009202602, design.md §13, R67) -- NUNCA incluye
  credenciales (`ConsultaEndpointCredencial`, R69): esas se crean
  directo en cada ambiente. `empresa_id` se exporta como
  `empresa_nombre` (no es portable entre bases).

  Los `.endpoint.json` huérfanos (de un Endpoint que ya no existe en la
  base local) se listan y solo se borran si se confirma
  (`Mix.Tasks.Meta.Huerfanos`, SPEC-SYS-0210202601 R6) -- EXCEPTO la
  marca de baja `{"eliminado": true}` que deja `mix endpoint.despublicar`,
  que nunca se toca acá (`ConsultaEndpoints.marca_de_baja?/2`).
  """

  def run(args) do
    Mix.Task.run("app.config")

    dir = List.first(args) || "priv/repo/catalogos"
    File.mkdir_p!(dir)

    {:ok, nombres, _apps} =
      Ecto.Migrator.with_repo(MetadataApp.Repo, fn _repo ->
        ConsultaEndpoints.listar_todos()
        |> Enum.map(&ConsultaEndpoints.exportar_endpoint(&1, dir))
      end)

    Mix.Tasks.Meta.Huerfanos.limpiar(dir, nombres, ".endpoint.json",
      excluir: &ConsultaEndpoints.marca_de_baja?(dir, &1)
    )

    Mix.shell().info("Exportados #{length(nombres)} Endpoint(s) a #{dir}/")
  end
end
