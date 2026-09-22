defmodule Mix.Tasks.Motor.PropagarExtension do
  use Mix.Task
  alias MetadataApp.{Ambientes, MotorAlta}

  @shortdoc "Propaga la imagen de un canal a otro, sin reconstruir (SPEC-SYS-0309202601)"

  @moduledoc """
  Uso: mix motor.propagar_extension <ambiente> <origen> <destino> [--commit=<hash>]

  Propagación entre canales (SPEC-SYS-0309202601/design.md §3) -- consulta
  qué imagen corre HOY en `<origen>` y la aplica tal cual sobre `<destino>`,
  disparando `actualizar-sistema.yml` (GitHub Actions) vía `gh workflow
  run`. Nunca hay build nuevo acá -- propagar es mover el MISMO artefacto
  ya construido de un canal al siguiente, jamás reconstruirlo. Se llamaba
  `mix motor.promover` -- renombrado (SPEC-SYS-1809202603 R1) para no
  colisionar en vocabulario con una futura propagación de artefactos de
  negocio.

  `--commit=<hash>` (SPEC-SYS-1809202603 R8) -- opcional. Sin el flag,
  comportamiento de siempre (toma la imagen que corre AHORA en
  `<origen>`). Con el flag, ignora `<origen>` para elegir la imagen --
  arma `<hash>` como el tag exacto a propagar, validado antes contra el
  registro de contenedores (nunca a ciegas: un hash mal tipeado se
  rechaza acá, nunca llega a disparar `actualizar-sistema.yml` con un
  tag inventado). Escenario real que lo motivó: `unstable` recibe un
  deploy automático en cada push a `main` -- si solo un commit puntual
  quedó validado sin errores, este flag permite propagar ESE, no "lo que
  corre ahora" a ciegas. Esto NO es rollback -- es elegir, hacia
  adelante, cuál commit YA presente en el origen se quiere propagar.

  Único par válido: `unstable -> testing` o `testing -> stable` -- ningún
  otro (nunca se saltea Testing, nunca al revés). Los dos saltos son
  manuales a propósito (decidido 2026-09-03, "todo manual por ahora").

  `<ambiente>` -- mismo argumento que ya usa `mix motor.alta`
  (`MetadataApp.Ambientes`/`MetadataApp.Ssh`): consultar la imagen actual
  de `<origen>` necesita SSH directo contra el clúster (mismo mecanismo de
  R8), y `Ambientes` es el único lugar donde viven esas credenciales -- no
  vale la pena inventar un segundo camino para lo mismo que ya resuelve
  `mix motor.alta`.

  Si `<destino>` ya está exactamente en la imagen de `<origen>`, no se
  dispara ningún workflow (SPEC-SYS-1809202603 R6) -- se avisa y termina
  sin hacer nada.
  """

  @pares_validos [{"unstable", "testing"}, {"testing", "stable"}]

  def run(args) do
    Mix.Task.run("app.config")

    {opts, resto, _invalidos} = OptionParser.parse(args, strict: [commit: :string])

    case resto do
      [nombre_ambiente, origen, destino] -> promover(nombre_ambiente, origen, destino, opts[:commit])
      _ -> Mix.raise("Uso: mix motor.propagar_extension <ambiente> <origen> <destino> [--commit=<hash>]")
    end
  end

  defp promover(nombre_ambiente, origen, destino, commit) do
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
        case resolver_imagen(ambiente, origen, commit) do
          {:error, mensaje} ->
            Mix.raise(mensaje)

          {:ok, imagen} ->
            Mix.shell().info("  #{imagen}")
            Mix.shell().info("== disparando actualizar-sistema.yml: \"#{destino}\" -> #{imagen} ==")

            case MotorAlta.disparar_actualizacion(ambiente, destino, imagen) do
              {:ok, :sin_cambios, mensaje} ->
                Mix.shell().info(mensaje)

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

  # Sin --commit: comportamiento de siempre (imagen actual de <origen>,
  # consultada por SSH). Con --commit: (SPEC-SYS-1809202603 R8) arma la
  # imagen de ESE commit puntual, validada contra el registro de
  # contenedores -- nunca consulta <origen> en este camino, la elección
  # explícita del operador reemplaza la inferencia.
  defp resolver_imagen(_ambiente, _origen, commit) when is_binary(commit) do
    Mix.shell().info("== validando que exista una imagen para el commit \"#{commit}\" ==")
    MotorAlta.imagen_para_commit(commit)
  end

  defp resolver_imagen(ambiente, origen, nil) do
    Mix.shell().info("== consultando imagen actual de \"#{origen}\" ==")

    case MotorAlta.imagen_actual(ambiente, origen) do
      {:error, mensaje} -> {:error, "No se pudo consultar la imagen de \"#{origen}\": #{mensaje}"}
      {:ok, imagen} -> {:ok, imagen}
    end
  end
end
