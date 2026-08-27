defmodule Mix.Tasks.Motor.Desplegar do
  use Mix.Task
  alias MetadataApp.Ambientes

  @shortdoc "Despliega la imagen ya construida en el ambiente elegido (pull + service update + setup)"

  @moduledoc """
  Uso: mix motor.desplegar <ambiente> [--imagen ghcr.io/.../metadata_stack:tag]

  Contraparte de "Ambientes de Deploy" (ver Sysadmin.AmbientesLive,
  MetadataApp.Ambientes) -- hasta esta entrega, el servidor de deploy
  vivía hardcodeado en 3 secrets fijos de GitHub Actions
  (DEPLOY_HOST/DEPLOY_USER/DEPLOY_SSH_KEY, usados igual por ci.yml y
  bc-deploy.yml), un solo ambiente posible. `gh workflow run` (lo que
  dispara `mix motor.publicar`) no puede pasar secrets como input --solo
  strings planos-- así que elegir servidor en tiempo de deploy no se
  puede resolver ADENTRO de esos workflows sin GitHub Environments (alta
  manual en la UI de GitHub, fuera del alcance de esta app).

  En cambio, este task hace el paso SSH DIRECTO desde la máquina de quien
  lo corre, con las credenciales del ambiente elegido (columna cifrada,
  ver MetadataApp.Encriptado) -- exactamente los mismos 4 pasos que ya
  hacía el job "deploy" de ci.yml/bc-deploy.yml (docker pull, service
  update --force, esperar 1/1, `docker exec .../app/bin/setup`), solo que
  parametrizados por ambiente en vez de fijos.

  No construye ni publica ninguna imagen -- asume que la imagen ya está
  en el registry (por un push a main normal, o por `mix motor.publicar`
  para un catálogo `pty_*`). `--imagen` sobreescribe el default guardado
  en el ambiente (`imagen_docker`), útil para desplegar un tag puntual
  (ej. un `:bc-<catalogo>-<run>` que `motor.publicar` ya empujó) en vez
  de `:latest`.

  Autenticación: usa la llave privada del ambiente si está configurada,
  si no la contraseña -- `mix motor.publicar`/CI usan clave (`ssh-action`
  con `DEPLOY_SSH_KEY`), pero algunos ambientes (ver el bootstrap de
  167.233.84.151, docs/onboarding-nuevo-sistema.md) solo tienen
  contraseña configurada todavía.
  """

  def run(args) do
    Mix.Task.run("app.config")

    {switches, args, _} = OptionParser.parse(args, strict: [imagen: :string])

    case args do
      [nombre] -> desplegar(nombre, switches[:imagen])
      _ -> Mix.raise("Uso: mix motor.desplegar <ambiente> [--imagen tag]")
    end
  end

  defp desplegar(nombre, imagen_override) do
    # MetadataApp.Vault.start_link/1 acá, ANTES de tocar el Repo, a
    # propósito -- este task necesita descifrar ssh_password/
    # ssh_llave_privada (Cloak.Ecto.Binary) de verdad, y Ecto.Migrator.
    # with_repo/3 (el patrón que ya usa mix motor.publicar) solo arranca
    # las apps de las que depende el Repo, nunca la app :metadata_app
    # completa -- sin esto el load fallaba con "cannot load ... as type
    # MetadataApp.Encriptado" (encontrado real probando este mismo task).
    # Mix.Task.run("app.start") habría arrancado TAMBIÉN
    # MetadataAppWeb.Endpoint (puerto 4000), chocando con un servidor de
    # dev ya corriendo -- Vault no depende del Repo, arranca solo.
    {:ok, _pid} = MetadataApp.Vault.start_link([])

    {:ok, resultado, _apps} =
      Ecto.Migrator.with_repo(MetadataApp.Repo, fn _repo -> Ambientes.obtener_ambiente_por_nombre(nombre) end)

    case resultado do
      nil ->
        nombres_disponibles =
          Ecto.Migrator.with_repo(MetadataApp.Repo, fn _repo -> Ambientes.listar_ambientes() end)
          |> elem(1)
          |> Enum.map_join(", ", & &1.nombre)

        Mix.raise("No existe ningún ambiente \"#{nombre}\". Disponibles: #{if nombres_disponibles == "", do: "(ninguno todavía)", else: nombres_disponibles}")

      ambiente ->
        imagen = imagen_override || ambiente.imagen_docker
        Mix.shell().info("== Desplegando #{imagen} en \"#{ambiente.nombre}\" (#{ambiente.ssh_usuario}@#{ambiente.host}) ==")

        case MetadataApp.Ssh.ejecutar(ambiente, comando_remoto(ambiente.docker_servicio, imagen)) do
          {:ok, 0, salida} ->
            Mix.shell().info(salida)
            Mix.shell().info("\n== Listo ==")

          {:ok, codigo, salida} ->
            Mix.shell().info(salida)
            Mix.raise("El deploy remoto terminó con código #{codigo} -- revisá la salida de arriba.")

          {:error, mensaje} ->
            Mix.raise(mensaje)
        end
    end
  end

  # Mismos 4 pasos que ya corrían fijos en ci.yml/bc-deploy.yml (job
  # "deploy"), sin cambiarles nada -- solo parametrizados por servicio/
  # imagen en vez de hardcodeados.
  defp comando_remoto(servicio, imagen) do
    """
    set -e
    docker pull #{imagen}
    docker service update --image #{imagen} --force #{servicio}

    echo "Esperando a que el servicio converja..."
    for i in $(seq 1 12); do
      REPLICAS=$(docker service ls --filter name=#{servicio} --format "{{.Replicas}}")
      echo "  replicas: $REPLICAS"
      if [ "$REPLICAS" = "1/1" ]; then break; fi
      sleep 5
    done

    CONTAINER_ID=$(docker ps -q --filter "name=#{servicio}" | head -n1)
    if [ -z "$CONTAINER_ID" ]; then
      echo "No se encontró el contenedor de #{servicio}, no se pudo migrar"
      exit 1
    fi
    docker exec "$CONTAINER_ID" /app/bin/setup
    """
  end
end
