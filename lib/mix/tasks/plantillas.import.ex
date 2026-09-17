defmodule Mix.Tasks.Plantillas.Import do
  use Mix.Task

  @shortdoc "Importa las plantillas del Constructor (Post Config) desde priv/repo/catalogos/*.plantillas.json"

  @moduledoc """
  Uso: mix plantillas.import [directorio_entrada]

  Default: priv/repo/catalogos/

  Crea/sincroniza las plantillas (Vistas + Impresión) leyendo cada
  `*.plantillas.json` del directorio (uno por catálogo, ver
  `mix plantillas.export`), resolviendo el catálogo por NOMBRE. Idempotente
  por (nombre, propósito) dentro de cada catálogo.

  Requiere que el catálogo ya exista — correr después de `mix meta.import`
  + `mix gen.catalogos`, nunca antes.

  Lógica real en `MetadataApp.MetaImportExport.importar_plantillas/1` — sin
  dependencia de Mix, para que `MetadataApp.Release` (producción, sin Mix)
  también la use vía `bin/import_meta`.
  """

  def run(args) do
    Mix.Task.run("app.config")
    dir = List.first(args) || "priv/repo/catalogos"

    {:ok, mensajes, _apps} =
      Ecto.Migrator.with_repo(MetadataApp.Repo, fn _repo ->
        MetadataApp.MetaImportExport.importar_plantillas(dir)
      end)

    Enum.each(mensajes, &Mix.shell().info/1)
  end
end
