defmodule Mix.Tasks.Motor.Import do
  use Mix.Task

  @shortdoc "Importa el autómata (estados/transiciones/reglas) desde priv/repo/catalogos/*.motor.json"

  @moduledoc """
  Uso: mix motor.import [directorio_entrada]

  Default: priv/repo/catalogos/

  Recrea estados/transiciones leyendo cada `*.motor.json` del directorio
  (uno por catálogo, ver `mix motor.export`), resolviendo toda referencia
  por NOMBRE, no por id. Idempotente: lo que ya existe (mismo nombre de
  estado; misma acción+origen de transición) se deja sin tocar.

  Requiere que el catálogo ya exista — correr después de `mix meta.import`
  + `mix gen.catalogos`, nunca antes.

  Lógica real en `MetadataApp.MetaImportExport.importar_motor/1` — sin
  dependencia de Mix, para que `MetadataApp.Release` (producción, sin Mix)
  también la use vía `bin/import_meta`.
  """

  def run(args) do
    Mix.Task.run("app.config")
    dir = List.first(args) || "priv/repo/catalogos"

    {:ok, mensajes, _apps} =
      Ecto.Migrator.with_repo(MetadataApp.Repo, fn _repo ->
        MetadataApp.MetaImportExport.importar_motor(dir)
      end)

    Enum.each(mensajes, &Mix.shell().info/1)
  end
end
