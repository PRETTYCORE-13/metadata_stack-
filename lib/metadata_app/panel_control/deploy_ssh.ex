defmodule MetadataApp.PanelControl.DeploySsh do
  @moduledoc """
  Llave SSH ed25519 compartida por TODOS los repos que
  `MetadataApp.PanelControl.Github` scaffoldea (una sola, no una por
  repo -- decisión 2026-08-31: mismo modelo de confianza que ya tiene un
  Ambiente, que ya comparte una única credencial para todo lo que hace
  `Desplegador`). Se guarda como una `MetadataApp.Integraciones.Credencial`
  más (`sistema_externo: "panel_control_deploy_ssh"`), generada
  perezosamente la primera vez que hace falta -- de ahí en más siempre
  se reusa la misma.

  La privada nunca queda en disco más que el instante que `ssh-keygen`
  la necesita para generarla/derivar la pública -- se lee a memoria y el
  archivo temporal se borra enseguida (`after` cubre también la salida
  por excepción), mismo criterio ya usado a mano esta sesión al armar el
  deploy automático del CRM.
  """

  alias MetadataApp.Integraciones

  @sistema "panel_control_deploy_ssh"

  @doc "Llave privada (string, formato OpenSSH) -- la genera la primera vez, reusa la ya guardada después."
  def obtener_o_generar_privada do
    case Integraciones.obtener_credencial_por_sistema(@sistema) do
      %{api_key: privada} when is_binary(privada) and privada != "" -> {:ok, privada}
      _ -> generar_y_guardar()
    end
  end

  @doc "Deriva la pública a partir de una privada ya obtenida -- nunca se guarda aparte, se recalcula cuando hace falta."
  def clave_publica(privada) do
    con_archivo_temporal(privada, fn ruta ->
      case System.cmd("ssh-keygen", ["-y", "-f", ruta], stderr_to_stdout: true) do
        {publica, 0} -> {:ok, String.trim(publica)}
        {salida, _codigo} -> {:error, "No se pudo derivar la clave pública de la llave de deploy: #{salida}"}
      end
    end)
  end

  # NOTA sobre "-N", "": correcto y probado contra Linux real (Bash, que
  # pasa el argv directo vía execve) -- production corre en un contenedor
  # Debian, mismo camino. En ESTA máquina de dev (Windows), invocar
  # ssh-keygen así vía `System.cmd`/puertos de Erlang (que arman la línea
  # de comando para CreateProcess, no execve) se cuelga -- mismo tipo de
  # problema que ya se vio esta sesión con el pipe de PowerShell hacia
  # `gh secret set`. No es un bug de este código: es una limitación de
  # probarlo desde Windows, no de cómo corre en producción. No "arreglar"
  # esto con el truco de `'""'` que sirvió en PowerShell -- ahí sí se
  # pasaría el string literal `""` (dos comillas) como passphrase real,
  # rompiendo la llave en Linux, que es donde esto importa de verdad.
  defp generar_y_guardar do
    dir = System.tmp_dir!()
    ruta = Path.join(dir, "panel_control_deploy_#{System.unique_integer([:positive])}")

    try do
      case System.cmd("ssh-keygen", ["-t", "ed25519", "-N", "", "-C", "panel-control-deploy", "-f", ruta], stderr_to_stdout: true) do
        {_salida, 0} ->
          privada = File.read!(ruta)
          guardar_credencial(privada)

        {salida, _codigo} ->
          {:error, "No se pudo generar la llave SSH de deploy: #{salida}"}
      end
    after
      File.rm(ruta)
      File.rm(ruta <> ".pub")
    end
  rescue
    e -> {:error, "Excepción generando la llave SSH de deploy: #{Exception.message(e)}"}
  end

  defp guardar_credencial(privada) do
    case Integraciones.crear_credencial(%{
           "nombre" => "Panel Control -- deploy SSH compartida",
           "sistema_externo" => @sistema,
           "api_key_nuevo" => privada
         }) do
      {:ok, _credencial} -> {:ok, privada}
      {:error, changeset} -> {:error, "No se pudo guardar la llave de deploy generada: #{inspect(changeset.errors)}"}
    end
  end

  defp con_archivo_temporal(contenido, fun) do
    dir = System.tmp_dir!()
    ruta = Path.join(dir, "panel_control_deploy_#{System.unique_integer([:positive])}")

    try do
      File.write!(ruta, contenido)
      File.chmod!(ruta, 0o600)
      fun.(ruta)
    after
      File.rm(ruta)
    end
  rescue
    e -> {:error, "Excepción usando la llave de deploy: #{Exception.message(e)}"}
  end
end
