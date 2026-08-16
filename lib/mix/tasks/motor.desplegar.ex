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

        case ejecutar_ssh(ambiente, comando_remoto(ambiente.docker_servicio, imagen)) do
          {:ok, 0} -> Mix.shell().info("\n== Listo ==")
          {:ok, codigo} -> Mix.raise("El deploy remoto terminó con código #{codigo} -- revisá la salida de arriba.")
          {:error, mensaje} -> Mix.raise(mensaje)
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

  # Shellea contra el binario `ssh` del sistema en vez del cliente nativo
  # de OTP (:ssh) -- se probó ese camino primero (sin temp files/askpass,
  # más "limpio" en teoría) pero la aplicación :ssh no está en el code
  # path de este Erlang en Windows (existe en disco, `:code.lib_dir(:ssh)`
  # igual da `{:error, :bad_name}` -- encontrado real probando esto) y
  # depender de una ruta de instalación de OTP a mano sería frágil para
  # cualquier otra máquina de desarrollo. `ssh` como binario, en cambio,
  # ya viene con git/WSL/OpenSSH nativo en cualquier entorno de dev
  # razonable.
  #
  # "-n" (redirige el stdin del ssh local desde /dev/null) es obligatorio
  # -- sin él, la sesión quedaba colgada DESPUÉS de que el comando remoto
  # ya había terminado de verdad (confirmado aparte por SSH: el servicio
  # convergía y /app/bin/setup corría en segundos) -- el output con barra
  # de progreso en vivo de `docker service update`/`docker pull`
  # interactúa mal con el stdin de ssh si no se cierra explícito.
  # System.cmd/3 no conecta stdin de por sí, pero eso no alcanzaba acá.
  defp ejecutar_ssh(%{ssh_llave_privada: llave} = ambiente, comando) when llave not in [nil, ""] do
    destino = destino(ambiente)

    en_directorio_temporal(fn dir ->
      llave_path = Path.join(dir, "llave")
      File.write!(llave_path, llave)
      File.chmod!(llave_path, 0o600)
      correr_ssh(["-i", llave_path, "-o", "PasswordAuthentication=no"], [], destino, comando)
    end)
  end

  defp ejecutar_ssh(%{ssh_password: senha} = ambiente, comando) when senha not in [nil, ""] do
    destino = destino(ambiente)

    en_directorio_temporal(fn dir ->
      pw_path = Path.join(dir, "pw")
      askpass_path = Path.join(dir, "askpass.sh")
      File.write!(pw_path, senha)
      File.chmod!(pw_path, 0o600)
      # cat de una ruta fija -- nunca interpola el secreto adentro de un
      # script que un shell podría reinterpretar (comillas, $, backticks
      # en la contraseña real no rompen nada acá).
      File.write!(askpass_path, "#!/bin/sh\ncat \"#{pw_path}\"\n")
      File.chmod!(askpass_path, 0o700)

      correr_ssh(
        ["-o", "PreferredAuthentications=password", "-o", "PubkeyAuthentication=no"],
        [{"SSH_ASKPASS", askpass_path}, {"SSH_ASKPASS_REQUIRE", "force"}],
        destino,
        comando
      )
    end)
  end

  defp ejecutar_ssh(_ambiente, _comando) do
    {:error, "Este ambiente no tiene contraseña ni llave privada configurada -- editalo en /sysadmin/ambientes."}
  end

  defp destino(ambiente), do: "#{ambiente.ssh_usuario}@#{ambiente.host}"

  defp en_directorio_temporal(usar) do
    dir = Path.join(System.tmp_dir!(), "motor_desplegar_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    try do
      usar.(dir)
    after
      File.rm_rf(dir)
    end
  end

  # Captura síncrona (no "into: IO.stream") a propósito -- confirmado real
  # probando esto: el deploy completo (docker pull + service update +
  # verify de Swarm, que puede tardar 1-3+ minutos de verdad) SIEMPRE
  # terminaba bien acá (salida completa, exit 0), los "cuelgues"/exit 255
  # sin mensaje que aparecían antes eran timeouts propios de las pruebas
  # (bash `timeout`/Stop-Process cortando a mitad de la fase "verify" de
  # Swarm, que YA es lenta de por sí) -- no un bug real de esta función.
  defp correr_ssh(opts_extra, env, destino, comando) do
    args = ["-n", "-o", "StrictHostKeyChecking=no"] ++ opts_extra ++ [destino, comando]
    {salida, codigo} = System.cmd("ssh", args, env: env, stderr_to_stdout: true)
    Mix.shell().info(salida)
    {:ok, codigo}
  rescue
    e in ErlangError -> {:error, "No se pudo ejecutar ssh: #{Exception.message(e)} -- ¿está instalado y en el PATH?"}
  end
end
