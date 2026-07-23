defmodule Mix.Tasks.Meta.Import do
  use Mix.Task

  @shortdoc "Importa Business Contexts desde priv/repo/catalogos/*.meta.json"

  @moduledoc """
  Uso: mix meta.import [directorio_entrada]

  Default: priv/repo/catalogos/

  Crea el Header + Detalles de cada `*.meta.json` del directorio (uno por
  catálogo, ver `mix meta.export`). Si un `schema_context_name` ya existe
  en la base, se deja sin tocar (no actualiza, no duplica). Es el paso
  previo a `mix gen.catalogos`, que deja la metadata cargada para que el
  generador pueda materializar los catálogos.

  Lógica real en `MetadataApp.MetaImportExport.importar_meta/1` — sin
  dependencia de Mix, para que `MetadataApp.Release` (producción, sin Mix)
  también la use vía `bin/import_meta`.
  """

  def run(args) do
    Mix.Task.run("app.config")
    dir = List.first(args) || "priv/repo/catalogos"

    {:ok, mensajes, _apps} =
      Ecto.Migrator.with_repo(MetadataApp.Repo, fn _repo ->
        MetadataApp.MetaImportExport.importar_meta(dir)
      end)

    Enum.each(mensajes, &Mix.shell().info/1)
  end
end
