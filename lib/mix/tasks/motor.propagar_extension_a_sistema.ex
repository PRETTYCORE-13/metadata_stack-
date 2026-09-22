defmodule Mix.Tasks.Motor.PropagarExtensionASistema do
  use Mix.Task
  alias MetadataApp.{Ambientes, MotorAlta}

  @shortdoc "Propaga una imagen ya construida a un sistema de cliente (SPEC-SYS-0309202601)"

  @moduledoc """
  Uso: mix motor.propagar_extension_a_sistema <ambiente> <sistema> <imagen>

  Apunta `metadata-<sistema>` (un CLIENTE de `priv/sistemas.json`, nunca un
  canal -- para mover un canal ver `mix motor.propagar_extension`) a una
  imagen ya construida, sin build nuevo -- dispara `actualizar-sistema.yml`
  (GitHub Actions) vía `gh workflow run`, mismo mecanismo que
  `mix motor.publicar`. Se llamaba `mix motor.actualizar` -- renombrado
  (SPEC-SYS-1809202603 R2) para no colisionar en vocabulario con una
  futura propagación de artefactos de negocio.

  `<ambiente>` -- agregado (SPEC-SYS-1809202603 R6-R7, antes este comando
  no lo pedía): la guarda de idempotencia necesita SSH real para consultar
  qué imagen corre AHORA MISMO en `<sistema>` antes de disparar nada --
  mismo criterio "nunca infiere" que ya usa `mix motor.propagar_extension`,
  y `Ambientes` es la única fuente real de esas credenciales.

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

  Si `<sistema>` ya está exactamente en `<imagen>`, no se dispara ningún
  workflow (R6) -- se avisa y termina sin hacer nada.
  """

  def run(args) do
    Mix.Task.run("app.config")

    case args do
      [nombre_ambiente, sistema, imagen] -> actualizar(nombre_ambiente, sistema, imagen)
      _ -> Mix.raise("Uso: mix motor.propagar_extension_a_sistema <ambiente> <sistema> <imagen>")
    end
  end

  defp actualizar(nombre_ambiente, sistema, imagen) do
    if not MotorAlta.sistema_registrado?(sistema) do
      Mix.raise("\"#{sistema}\" no está de alta (no aparece en priv/sistemas.json) -- no se puede actualizar.")
    end

    {:ok, _pid} = MetadataApp.Vault.start_link([])

    {:ok, ambiente, _apps} =
      Ecto.Migrator.with_repo(MetadataApp.Repo, fn _repo -> Ambientes.obtener_ambiente_por_nombre(nombre_ambiente) end)

    case ambiente do
      nil ->
        Mix.raise("No existe ningún ambiente \"#{nombre_ambiente}\".")

      ambiente ->
        Mix.shell().info("== disparando actualizar-sistema.yml: \"#{sistema}\" -> #{imagen} ==")

        case MotorAlta.disparar_actualizacion(ambiente, sistema, imagen) do
          {:ok, :sin_cambios, mensaje} ->
            Mix.shell().info(mensaje)

          {:ok, salida} ->
            Mix.shell().info(salida)
            Mix.shell().info("Disparado -- seguí el progreso con \"gh run list\" / \"gh run watch\".")

          {:error, mensaje} ->
            Mix.raise(mensaje)
        end
    end
  end
end
