defmodule Mix.Tasks.Motor.Actualizar do
  use Mix.Task
  alias MetadataApp.MotorAlta

  @shortdoc "Actualiza un sistema de cliente a una imagen ya construida (SPEC-SYS-0309202601)"

  @moduledoc """
  Uso: mix motor.actualizar <sistema> <imagen>

  Apunta `metadata-<sistema>` (un CLIENTE de `priv/sistemas.json`, nunca un
  canal -- para mover un canal ver `mix motor.promover`) a una imagen ya
  construida, sin build nuevo -- dispara `actualizar-sistema.yml`
  (GitHub Actions) vía `gh workflow run`, mismo mecanismo que
  `mix motor.publicar`.

  `<sistema>` -- validado acá contra `priv/sistemas.json`
  (`MotorAlta.sistema_registrado?/1`) antes de disparar nada, mismo
  criterio que `mix motor.publicar`/`mix motor.despublicar` (R5/R6): un
  nombre que no está de alta se rechaza acá, nunca llega a tocar k3s.

  `<imagen>` -- siempre explícita, sin default -- el workflow del otro
  lado (`actualizar-sistema.yml`) valida ADEMÁS que sea EXACTO lo que corre
  ahora mismo en `metadata-stable` (consultado en vivo contra k3s, R6/R8) y
  rechaza si no coincide: ningún cliente puede terminar con una imagen que
  nunca pasó por los tres canales (unstable -> testing -> stable), sin
  importar quién dispare este comando o desde dónde.
  """

  def run(args) do
    Mix.Task.run("app.config")

    case args do
      [sistema, imagen] -> actualizar(sistema, imagen)
      _ -> Mix.raise("Uso: mix motor.actualizar <sistema> <imagen>")
    end
  end

  defp actualizar(sistema, imagen) do
    if not MotorAlta.sistema_registrado?(sistema) do
      Mix.raise("\"#{sistema}\" no está de alta (no aparece en priv/sistemas.json) -- no se puede actualizar.")
    end

    Mix.shell().info("== disparando actualizar-sistema.yml: \"#{sistema}\" -> #{imagen} ==")

    case MotorAlta.disparar_actualizacion(sistema, imagen) do
      {:ok, salida} ->
        Mix.shell().info(salida)
        Mix.shell().info("Disparado -- seguí el progreso con \"gh run list\" / \"gh run watch\".")

      {:error, mensaje} ->
        Mix.raise(mensaje)
    end
  end
end
