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

  Sincroniza el directorio con el estado actual: un Endpoint que ya no
  existe deja su `.endpoint.json` huérfano, que se borra
  automáticamente acá -- EXCEPTO si el contenido actual del archivo es
  exactamente el tombstone `{"eliminado": true}` que deja `mix
  endpoint.despublicar`, que nunca se toca acá (es responsabilidad
  exclusiva de esa tarea).
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

    limpiar_huerfanos(dir, nombres)
    Mix.shell().info("Exportados #{length(nombres)} Endpoint(s) a #{dir}/")
  end

  # Mismo criterio que Mix.Tasks.Meta.Export.limpiar_huerfanos/3, con
  # una excepción: un archivo cuyo contenido ya es el tombstone de
  # "mix endpoint.despublicar" no es un huérfano de verdad -- es el
  # registro explícito de una baja ya publicada, y esta tarea (que
  # corre como parte de CUALQUIER `mix motor.publicar` normal) no
  # puede borrarlo sin deshacer esa baja en el próximo deploy.
  defp limpiar_huerfanos(dir, nombres_vigentes) do
    esperados = MapSet.new(nombres_vigentes, &"#{&1}.endpoint.json")

    dir
    |> File.ls!()
    |> Enum.filter(&String.ends_with?(&1, ".endpoint.json"))
    |> Enum.reject(&MapSet.member?(esperados, &1))
    |> Enum.reject(&tombstone?(dir, &1))
    |> Enum.each(fn archivo ->
      File.rm!(Path.join(dir, archivo))
      Mix.shell().info("  (huérfano borrado: #{archivo})")
    end)
  end

  defp tombstone?(dir, archivo) do
    case dir |> Path.join(archivo) |> File.read() do
      {:ok, contenido} -> match?({:ok, %{"eliminado" => true}}, Jason.decode(contenido))
      {:error, _} -> false
    end
  end
end
