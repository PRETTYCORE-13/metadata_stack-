defmodule Mix.Tasks.Motor.Publicar do
  use Mix.Task
  alias MetadataApp.MetaEstadosAdmin

  @shortdoc "Empaqueta un catálogo (API+autómata+reglas) y arma el commit para publicarlo"

  @moduledoc """
  Uso: mix motor.publicar <catalogo>

  Automatiza los pasos de "empaquetar para producción" (validar, exportar
  catálogo+autómata, git add+commit) descriptos en el flujo de publicación
  del motor. El `git push` queda deliberadamente AFUERA de este task: es
  una acción visible para el resto del equipo (compartimos `origin/main`),
  requiere confirmación humana antes de mandar algo ahí.

  Pasos:
    1. `MetaEstadosAdmin.validar_motor/1` — aborta si hay errores estructurales
       (no llega a tocar git si el autómata está roto).
    2. `mix meta.export` (regenera `priv/repo/catalogos/*.meta.json` — de
       TODOS los catálogos, no solo este, mismo comportamiento de siempre,
       pero un archivo por catálogo así solo cambia el que de verdad se tocó).
    3. `mix motor.export` (ídem para `priv/repo/catalogos/*.motor.json`).
    4. `git add` de `<catalogo>.meta.json` + `<catalogo>.motor.json` (si
       existe) + la carpeta de reglas de negocio del catálogo
       (`lib/metadata_app/meta_business_process/reglas/<catalogo>/`, si existe)
       — nunca de los archivos de otros catálogos, aunque el export los
       haya regenerado a todos.
    5. `git commit` **acotado a esas mismas rutas** (`git commit -- <rutas>`,
       no un `git commit` a secas) — así el commit resultante solo contiene
       lo de este catálogo aunque haya OTROS cambios sin relación ya
       agregados al staging area por el desarrollador (ej. un WIP a medio
       commitear). No barre el índice completo.
  """

  def run([]), do: Mix.raise("Uso: mix motor.publicar <catalogo>")

  def run([catalogo | _resto]) do
    Mix.Task.run("app.config")

    Mix.shell().info("== validando \"#{catalogo}\" ==")
    validar!(catalogo)

    Mix.shell().info("\n== exportando catálogo + autómata ==")
    Mix.Task.rerun("meta.export")
    Mix.Task.rerun("motor.export")

    Mix.shell().info("\n== git add + commit ==")
    rutas = git_add(catalogo)
    git_commit(catalogo, rutas)

    Mix.shell().info(
      "\n\"#{catalogo}\" empaquetado y commiteado local. Revisá \"git log -1\" y corré \"git push\" a mano cuando estés listo."
    )
  end

  defp validar!(catalogo) do
    {:ok, resultado, _apps} =
      Ecto.Migrator.with_repo(MetadataApp.Repo, fn _repo -> MetaEstadosAdmin.validar_motor(catalogo) end)

    case resultado do
      {:error, motivo} ->
        Mix.raise("#{catalogo}: #{motivo}")

      {:ok, %{problemas: problemas, valido?: valido?}} ->
        Enum.each(problemas, fn p ->
          etiqueta = if p.severidad == :error, do: "ERROR", else: "advertencia"
          Mix.shell().info("  [#{etiqueta}] #{p.mensaje}")
        end)

        if problemas == [] do
          Mix.shell().info("  sin problemas")
        end

        unless valido? do
          Mix.raise("\"#{catalogo}\" no pasa validar_motor — corregí los errores de arriba antes de publicar.")
        end
    end
  end

  defp git_add(catalogo) do
    carpeta_reglas = Path.join(["lib", "metadata_app", "meta_business_process", "reglas", catalogo])

    archivos_catalogo =
      ["priv/repo/catalogos/#{catalogo}.meta.json", "priv/repo/catalogos/#{catalogo}.motor.json"]
      |> Enum.filter(&File.exists?/1)

    rutas = archivos_catalogo ++ if File.dir?(carpeta_reglas), do: [carpeta_reglas], else: []

    case Mix.shell().cmd("git add #{Enum.join(rutas, " ")}") do
      0 -> rutas
      status -> Mix.raise("git add falló (status #{status})")
    end
  end

  # El "-- rutas" es lo que evita que este commit se lleve puesto cualquier
  # otro cambio que el desarrollador ya tuviera en el staging area sin
  # relación con este catálogo — "git commit -m" a secas commitea TODO el
  # índice, no solo lo que este task acaba de agregar.
  defp git_commit(catalogo, rutas) do
    mensaje = "Agrega catálogo #{catalogo} (API + autómata + reglas)"

    case Mix.shell().cmd(~s(git commit -m "#{mensaje}" -- #{Enum.join(rutas, " ")})) do
      0 -> :ok
      status -> Mix.raise("git commit falló (status #{status}) — ¿no había nada nuevo para commitear?")
    end
  end
end
