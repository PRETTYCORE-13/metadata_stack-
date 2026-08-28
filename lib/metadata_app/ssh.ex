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
      restringir_permisos_secreto(llave_path)
      correr(["-i", llave_path, "-o", "PasswordAuthentication=no"], [], destino, comando)
    end)
  end

  def ejecutar(%{ssh_password: senha} = ambiente, comando) when senha not in [nil, ""] do
    destino = destino(ambiente)

    en_directorio_temporal(fn dir ->
      pw_path = Path.join(dir, "pw")
      File.write!(pw_path, senha)
      restringir_permisos_secreto(pw_path)
      askpass_path = escribir_askpass(dir, pw_path)

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

  # File.chmod!(path, 0o600) no alcanza en Windows -- el bit de modo POSIX
  # que Erlang expone ahí no controla las ACLs reales de NTFS, así que el
  # archivo sigue siendo legible por más que el usuario actual (heredado
  # del directorio temporal), y el propio `ssh` cliente lo rechaza con
  # "UNPROTECTED PRIVATE KEY FILE" (encontrado real probando Panel Control
  # desde una máquina de desarrollo Windows, 2026-08-27) -- en Linux
  # (producción) nunca pasó porque chmod ahí sí es real. `icacls` es el
  # equivalente nativo de Windows: tira toda ACL heredada y deja al
  # usuario actual como único con permiso de lectura. Se usa tanto para la
  # llave privada como para el archivo de contraseña (mismo requisito).
  defp restringir_permisos_secreto(path) do
    case :os.type() do
      {:win32, _} ->
        usuario = System.get_env("USERNAME") || raise "No se pudo determinar el usuario actual (USERNAME) para restringir permisos del secreto"
        {_salida, 0} = System.cmd("icacls", [path, "/inheritance:r", "/grant:r", "#{usuario}:R"], stderr_to_stdout: true)
        :ok

      _ ->
        File.chmod!(path, 0o600)
    end
  end

  # El helper de SSH_ASKPASS tiene que ser un ejecutable de verdad, no un
  # script interpretado por shebang -- en Linux/macOS un `#!/bin/sh` andaba
  # bien, pero en Windows el propio `ssh` (el de Git for Windows/MSYS, el
  # que termina en el PATH de una app Elixir corriendo nativo, sin pasar
  # por una shell MSYS) lo invoca con CreateProcess DIRECTO sobre ese
  # archivo -- sin arrancar ninguna shell que interprete el shebang, así
  # que explota con "CreateProcessW failed error:193" / "ssh_askpass:
  # posix_spawnp: Unknown error" (encontrado real, 2026-08-28, probando
  # Panel Control desde una máquina de desarrollo Windows). Un `.cmd` SÍ
  # lo ejecuta bien -- confirmado real contra el servidor de producción.
  #
  # PERO tiene que ser con backslashes, no forward slashes -- Path.join/
  # System.tmp_dir! en Elixir arman rutas con "/" (estilo "portable") aun
  # en Windows, y ese mismo mecanismo de auto-despacho de Windows para
  # ejecutar un .cmd (sin pasar por una shell POSIX) NO encuentra el
  # archivo si la ruta viene con "/": falla con "El sistema no puede
  # encontrar el archivo especificado" (encontrado real, mismo día) --
  # aplica tanto a la ruta del .cmd (SSH_ASKPASS) como a la ruta de la
  # contraseña referenciada ADENTRO de su contenido.
  defp escribir_askpass(dir, pw_path) do
    case :os.type() do
      {:win32, _} ->
        askpass_path = Path.join(dir, "askpass.cmd")
        File.write!(askpass_path, "@type \"#{a_backslashes(pw_path)}\"\r\n")
        a_backslashes(askpass_path)

      _ ->
        askpass_path = Path.join(dir, "askpass.sh")
        # cat de una ruta fija -- nunca interpola el secreto adentro de un
        # script que un shell podría reinterpretar (comillas, $, backticks
        # en la contraseña real no rompen nada acá).
        File.write!(askpass_path, "#!/bin/sh\ncat \"#{pw_path}\"\n")
        File.chmod!(askpass_path, 0o700)
        askpass_path
    end
  end

  defp a_backslashes(path), do: String.replace(path, "/", "\\")

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
