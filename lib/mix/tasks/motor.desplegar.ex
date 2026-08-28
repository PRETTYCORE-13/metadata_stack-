defmodule Mix.Tasks.Motor.Desplegar do
  use Mix.Task
  alias MetadataApp.Ambientes

  @shortdoc "Despliega la imagen ya construida en el ambiente elegido (pull + service update + setup)"

  @moduledoc """
  Uso: mix motor.desplegar <ambiente> [--imagen ghcr.io/.../metadata_stack:tag]

  Contraparte de "Ambientes de Deploy" (ver Sysadmin.AmbientesLive,
  MetadataApp.Ambientes) -- hace el paso SSH DIRECTO desde la máquina de
  quien lo corre, con las credenciales del ambiente elegido (columna
  cifrada, ver MetadataApp.Encriptado), parametrizado por ambiente en vez
  de fijo (a diferencia de ci.yml/bc-deploy.yml, que siguen apuntando
  siempre al mismo servidor de oficina vía 3 secrets fijos de GitHub
  Actions -- ver docs/ci-cd-deploy.md).

  Desde la migración de 167.233.84.151 a k3s (2026-08-26/27), este task
  asume que CUALQUIER ambiente corre k3s -- namespace/deployment fijos
  (`metadata-stack`/`metadata-stack-app`, mismos nombres que dejó esa
  migración), no Docker Swarm. `ambiente.docker_servicio` quedó sin uso
  acá (columna vestigial de cuando el único servidor era Swarm) -- si
  algún día vuelve a hacer falta desplegar contra un Ambiente Swarm real,
  esto necesita un campo por-ambiente para elegir el mecanismo, no un
  hardcode global como este.

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

        case MetadataApp.Ssh.ejecutar(ambiente, comando_remoto(imagen)) do
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

  @namespace "metadata-stack"
  @deployment "metadata-stack-app"

  # Equivalente en k3s de los 4 pasos que este task hacía contra Docker
  # Swarm (docker pull + service update --force + esperar 1/1 + docker
  # exec .../app/bin/setup) -- namespace/deployment fijos, mismos nombres
  # que dejó la migración a k3s de 167.233.84.151 (2026-08-26/27).
  # `rollout restart` (no solo `set image`) es necesario porque el tag
  # `latest` casi nunca cambia de nombre entre deploys -- sin forzar un
  # nuevo rollout, un `set image` a la MISMA imagen no dispara nada
  # (mismo motivo que Swarm necesitaba `--force`).
  defp comando_remoto(imagen) do
    """
    set -e
    sudo k3s kubectl set image deployment/#{@deployment} app=#{imagen} -n #{@namespace}
    sudo k3s kubectl rollout restart deployment/#{@deployment} -n #{@namespace}

    echo "Esperando a que el rollout converja..."
    sudo k3s kubectl rollout status deployment/#{@deployment} -n #{@namespace} --timeout=120s

    POD=$(sudo k3s kubectl get pod -n #{@namespace} -l app=#{@deployment} -o jsonpath='{.items[0].metadata.name}')
    if [ -z "$POD" ]; then
      echo "No se encontró el pod de #{@deployment}, no se pudo migrar"
      exit 1
    fi
    sudo k3s kubectl exec -n #{@namespace} "$POD" -- /app/bin/setup
    """
  end
end
