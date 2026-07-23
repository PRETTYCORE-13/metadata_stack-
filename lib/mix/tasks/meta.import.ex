defmodule Mix.Tasks.Meta.Import do
  use Mix.Task
  alias MetadataApp.BusinessProcessBuilder.MetaSchemaContext

  @shortdoc "Importa Business Contexts desde priv/repo/catalogos/*.meta.json"

  @moduledoc """
  Uso: mix meta.import [directorio_entrada]

  Default: priv/repo/catalogos/

  Crea el Header + Detalles de cada `*.meta.json` del directorio (uno por
  catálogo, ver `mix meta.export`). Si un `schema_context_name` ya existe
  en la base, se deja sin tocar (no actualiza, no duplica). Es el paso
  previo a `mix gen.catalogos`, que deja la metadata cargada para que el
  generador pueda materializar los catálogos.
  """

  def run(args) do
    Mix.Task.run("app.config")

    dir = List.first(args) || "priv/repo/catalogos"

    # Directorio ausente = cero catálogos para importar, no un error — es
    # el estado normal de un checkout limpio desde que ningún pty_* vive
    # en git (ver .gitignore): git no trackea directorios vacíos, así que
    # si nadie desplegó todavía ningún BC, esta carpeta ni existe.
    contextos =
      if File.dir?(dir) do
        dir
        |> File.ls!()
        |> Enum.filter(&String.ends_with?(&1, ".meta.json"))
      else
        []
      end
      |> Enum.sort()
      |> Enum.map(&(dir |> Path.join(&1) |> File.read!() |> Jason.decode!()))

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
