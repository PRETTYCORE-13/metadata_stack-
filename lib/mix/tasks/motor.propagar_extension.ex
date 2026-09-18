defmodule Mix.Tasks.Motor.Promover do
  use Mix.Task
  alias MetadataApp.{Ambientes, MotorAlta}

  @shortdoc "Promueve la imagen de un canal a otro, sin reconstruir (SPEC-SYS-0309202601)"

  @moduledoc """
  Uso: mix motor.promover <ambiente> <origen> <destino>

  Promoción entre canales (design.md §3) -- consulta qué imagen corre HOY
  en `<origen>` y la aplica tal cual sobre `<destino>`, disparando
  `actualizar-sistema.yml` (GitHub Actions) vía `gh workflow run`. Nunca
  hay build nuevo acá -- promover es mover el MISMO artefacto ya
  construido de un canal al siguiente, jamás reconstruirlo.

  Único par válido: `unstable -> testing` o `testing -> stable` -- ningún
  otro (nunca se saltea Testing, nunca al revés). Los dos saltos son
  manuales a propósito (decidido 2026-09-03, "todo manual por ahora").

  `<ambiente>` -- mismo argumento que ya usa `mix motor.alta`
  (`MetadataApp.Ambientes`/`MetadataApp.Ssh`): consultar la imagen actual
  de `<origen>` necesita SSH directo contra el clúster (mismo mecanismo de
  R8), y `Ambientes` es el único lugar donde viven esas credenciales -- no
  vale la pena inventar un segundo camino para lo mismo que ya resuelve
  `mix motor.alta`.
  """

  @pares_validos [{"unstable", "testing"}, {"testing", "stable"}]

  def run(args) do
    Mix.Task.run("app.config")

    case args do
      [nombre_ambiente, origen, destino] -> promover(nombre_ambiente, origen, destino)
      _ -> Mix.raise("Uso: mix motor.promover <ambiente> <origen> <destino>")
    end
  end

  defp promover(nombre_ambiente, origen, destino) do
    if {origen, destino} not in @pares_validos do
      Mix.raise(
        "\"#{origen} -> #{destino}\" no es una promoción válida -- solo \"unstable -> testing\" o " <>
          "\"testing -> stable\" (nunca se saltea Testing, nunca al revés)."
      )
    end

    {:ok, _pid} = MetadataApp.Vault.start_link([])

    {:ok, ambiente, _apps} =
      Ecto.Migrator.with_repo(MetadataApp.Repo, fn _repo -> Ambientes.obtener_ambiente_por_nombre(nombre_ambiente) end)

    case ambiente do
      nil ->
        Mix.raise("No existe ningún ambiente \"#{nombre_ambiente}\".")

      ambiente ->
        Mix.shell().info("== consultando imagen actual de \"#{origen}\" ==")

        case MotorAlta.imagen_actual(ambiente, origen) do
          {:error, mensaje} ->
            Mix.raise("No se pudo consultar la imagen de \"#{origen}\": #{mensaje}")

          {:ok, imagen} ->
            Mix.shell().info("  #{imagen}")
            Mix.shell().info("== disparando actualizar-sistema.yml: \"#{destino}\" -> #{imagen} ==")

            case MotorAlta.disparar_actualizacion(destino, imagen) do
              {:ok, salida} ->
                Mix.shell().info(salida)

                Mix.shell().info(
                  "Disparado -- \"#{destino}\" va camino a #{imagen}. Seguí el progreso con \"gh run list\" / \"gh run watch\"."
                )

              {:error, mensaje} ->
                Mix.raise(mensaje)
            end
        end
    end
  end
end
