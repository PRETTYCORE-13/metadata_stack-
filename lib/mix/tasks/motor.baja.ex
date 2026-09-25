defmodule Mix.Tasks.Motor.Baja do
  use Mix.Task
  alias MetadataApp.{Ambientes, MotorAlta}

  @shortdoc "Da de baja un sistema existente (contraparte de motor.alta) -- SPEC-ARQ-1709202603"

  @moduledoc """
  Uso: mix motor.baja <ambiente> <sistema>

  Mecanismo de baja de un sistema existente -- ver
  `docs/specs/SPEC-ARQ-1709202603-baja-sistema/01.requirements.md` para los
  requisitos (R1-R7). Contraparte de `mix motor.alta`: respalda la base
  de datos (R7, `pg_dump` a `/home/elixir/backups/` en el servidor), borra
  el Deployment/Service/Secret en k3s, la base, el registro DNS y el
  bloque de Caddy de `<sistema>`, y lo quita de `priv/sistemas.json` -- en
  ese orden.

  `<ambiente>` -- mismo argumento que `mix motor.alta`
  (`MetadataApp.Ambientes`/`MetadataApp.Ssh`).

  Pide confirmación explícita (repetir el nombre del sistema, R3) antes de
  tocar nada -- el borrado de la base de datos es irreversible y este
  mecanismo no hace backup solo (ver "Preguntas abiertas" del spec).

  Cada paso es idempotente (R4): reintentar la baja sobre un sistema que
  ya quedó parcialmente borrado retoma donde cortó en vez de fallar.
  """

  def run(args) do
    Mix.Task.run("app.config")

    case args do
      [nombre_ambiente, sistema] -> baja(nombre_ambiente, sistema)
      _ -> Mix.raise("Uso: mix motor.baja <ambiente> <sistema>")
    end
  end

  defp baja(nombre_ambiente, sistema) do
    case MotorAlta.validar_puede_bajar(sistema) do
      {:error, mensaje} ->
        Mix.raise(mensaje)

      {:ok, _sistema} ->
        # Mismo orden que motor.alta.ex: Vault ANTES de tocar el Repo
        # (necesita descifrar ssh_password/ssh_llave_privada y la api_key
        # de Cloudflare), y Ecto.Migrator.with_repo/3 en vez de
        # Mix.Task.run("app.start") para no levantar el Endpoint.
        {:ok, _pid} = MetadataApp.Vault.start_link([])
        {:ok, _} = Application.ensure_all_started(:req)

        {:ok, ambiente, _apps} =
          Ecto.Migrator.with_repo(MetadataApp.Repo, fn _repo -> Ambientes.obtener_ambiente_por_nombre(nombre_ambiente) end)

        case ambiente do
          nil ->
            Mix.raise("No existe ningún ambiente \"#{nombre_ambiente}\".")

          ambiente ->
            confirmar!(sistema)
            ejecutar_baja(ambiente, sistema)
        end
    end
  end

  # R3: confirmación explícita repitiendo el nombre -- no alcanza con un
  # simple s/n, tiene que escribir el nombre exacto para que un Enter de
  # más (o copiar/pegar el comando entero sin pensarlo) no dé de baja el
  # sistema equivocado por accidente.
  defp confirmar!(sistema) do
    Mix.shell().info("""

    Vas a dar de baja "#{sistema}" por completo:
      - su base de datos (db_#{sistema})
      - su Deployment/Service/Secret en k3s
      - su registro DNS y su bloque en Caddy
      - su entrada en priv/sistemas.json

    Este paso es IRREVERSIBLE -- la base de datos se borra sin backup automático.
    """)

    respuesta =
      Mix.shell().prompt("Escribí el nombre del sistema (\"#{sistema}\") para confirmar:")
      |> String.trim()

    if respuesta != sistema do
      Mix.raise("Confirmación no coincide (\"#{respuesta}\" != \"#{sistema}\") -- baja cancelada, no se tocó nada.")
    end
  end

  defp ejecutar_baja(ambiente, sistema) do
    with _ <- Mix.shell().info("== respaldando db_#{sistema} antes de tocar nada =="),
         {:ok, resultado_backup} <- MotorAlta.respaldar_base(ambiente, sistema),
         _ <- reportar_backup(resultado_backup),
         _ <- Mix.shell().info("== borrando deployment/service/secret de \"#{sistema}\" en k3s =="),
         {:ok, salida_k3s} <- MotorAlta.borrar_deployment(ambiente, sistema),
         _ <- Mix.shell().info(salida_k3s),
         _ <- Mix.shell().info("== borrando db_#{sistema} =="),
         {:ok, salida_db} <- MotorAlta.borrar_base(ambiente, sistema),
         _ <- Mix.shell().info(salida_db),
         _ <- Mix.shell().info("== quitando DNS + Caddy =="),
         # exponer_dominio/3 (motor.alta.ex) hace lo mismo -- Cloudflare
         # necesita el Repo (credencial cifrada) para leer/borrar el
         # registro DNS, y el with_repo/3 de más arriba ya se cerró apenas
         # terminó de resolver `ambiente` (es de un solo uso, no queda
         # corriendo para el resto de la task).
         {:ok, resultado_dominio, _apps} <-
           Ecto.Migrator.with_repo(MetadataApp.Repo, fn _repo -> MotorAlta.quitar_dominio(ambiente, sistema) end),
         {:ok, salida_dominio} <- resultado_dominio,
         _ <- Mix.shell().info(salida_dominio),
         _ <- Mix.shell().info("== quitando de priv/sistemas.json =="),
         {:ok, :desregistrado} <- MotorAlta.desregistrar_sistema(sistema),
         _ <- Mix.shell().info("desregistrado, comiteado y pusheado."),
         _ <- Mix.shell().info("== verificando que no quede nada =="),
         {:ok, :limpio} <- MotorAlta.verificar_baja(ambiente, sistema) do
      Mix.shell().info("\"#{sistema}\" está dado de baja -- sin rastro en k3s ni en Caddy.")
    else
      {:error, mensaje} -> Mix.raise("Baja de \"#{sistema}\" falló:\n#{mensaje}")
    end
  end

  defp reportar_backup(:ya_no_existia), do: Mix.shell().info("(no había base que respaldar, ya estaba borrada de un intento anterior)")
  defp reportar_backup(ruta), do: Mix.shell().info("respaldo guardado en #{ruta}")
end
