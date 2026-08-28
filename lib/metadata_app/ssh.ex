defmodule MetadataApp.Ssh do
  @moduledoc """
  Ejecución de comandos remotos por SSH contra un `MetadataApp.Ambientes.Ambiente`
  -- extraído de `Mix.Tasks.Motor.Desplegar` (2026-08-16) para que
  `MetadataApp.PanelControl.Desplegador` (Panel Control, 2026-08-26) pueda
  reusar exactamente la misma autenticación (clave o contraseña, nunca
  escrita a disco fuera de un directorio temporal de vida corta) en vez de
  duplicarla.

  Shellea contra el binario `ssh` del sistema en vez del cliente nativo de
  OTP (:ssh) -- la app :ssh no está en el code path de este Erlang en
  Windows (confirmado real: `:code.lib_dir(:ssh)` da `{:error, :bad_name}`
  pese a existir en disco), y depender de una ruta de instalación de OTP a
  mano sería frágil para cualquier otra máquina de desarrollo. `ssh` como
  binario ya viene con git/WSL/OpenSSH nativo en cualquier entorno de dev
  razonable.
  """

  @doc "Corre `comando` en `ambiente` por SSH -- clave privada si está configurada, si no contraseña."
  def ejecutar(%{ssh_llave_privada: llave} = ambiente, comando) when llave not in [nil, ""] do
    destino = destino(ambiente)

    en_directorio_temporal(fn dir ->
      llave_path = Path.join(dir, "llave")
      File.write!(llave_path, llave)
      File.chmod!(llave_path, 0o600)
      correr(["-i", llave_path, "-o", "PasswordAuthentication=no"], [], destino, comando)
    end)
  end

  def ejecutar(%{ssh_password: senha} = ambiente, comando) when senha not in [nil, ""] do
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

      correr(
        ["-o", "PreferredAuthentications=password", "-o", "PubkeyAuthentication=no"],
        [{"SSH_ASKPASS", askpass_path}, {"SSH_ASKPASS_REQUIRE", "force"}],
        destino,
        comando
      )
    end)
  end

  def ejecutar(_ambiente, _comando) do
    {:error, "Este ambiente no tiene contraseña ni llave privada configurada -- editalo en /sysadmin/ambientes."}
  end

  defp destino(ambiente), do: "#{ambiente.ssh_usuario}@#{ambiente.host}"

  defp en_directorio_temporal(usar) do
    dir = Path.join(System.tmp_dir!(), "ssh_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    try do
      usar.(dir)
    after
      File.rm_rf(dir)
    end
  end

  # Captura síncrona (no "into: IO.stream") a propósito -- confirmado real
  # con mix motor.desplegar: comandos remotos que tardan minutos (docker
  # pull + service update + verify de Swarm) siempre terminan bien acá,
  # los "cuelgues" que aparecían antes eran timeouts propios de quien
  # ejecuta, no un bug de esta función. "-n" (stdin del ssh local desde
  # /dev/null) es obligatorio -- sin él la sesión queda colgada después de
  # que el comando remoto ya terminó de verdad. "UserKnownHostsFile=/dev/null"
  # -- desde Panel Control esto corre como el usuario "nobody" del
  # contenedor final (Dockerfile), sin $HOME real para escribir
  # known_hosts; como ya no verificamos el host key (StrictHostKeyChecking
  # =no), no tiene sentido que ssh intente persistirlo en ningún lado.
  # "LogLevel=ERROR" -- sin esto, ssh imprime "Warning: Permanently added
  # ... to the list of known hosts" en la PRIMERA conexión desde un pod
  # nuevo (aunque el destino sea /dev/null, ese aviso sale igual) --
  # encontrado real: Desplegador.agregar_a_caddy/3 hace un "leer archivo
  # remoto por ssh" y ese warning se colaba adentro del contenido leído,
  # corrompiendo el Caddyfile reescrito ("unrecognized directive:
  # Warning"). motor.desplegar no lo necesitaba (nadie mezcla el output
  # con nada), pero acá exige salida limpia.
  defp correr(opts_extra, env, destino, comando) do
    args =
      ["-n", "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null", "-o", "LogLevel=ERROR"] ++
        opts_extra ++ [destino, comando]
    {salida, codigo} = System.cmd("ssh", args, env: env, stderr_to_stdout: true)
    {:ok, codigo, salida}
  rescue
    e in ErlangError -> {:error, "No se pudo ejecutar ssh: #{Exception.message(e)} -- ¿está instalado y en el PATH?"}
  end
end
