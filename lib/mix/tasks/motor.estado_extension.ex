defmodule Mix.Tasks.Motor.EstadoExtension do
  use Mix.Task
  alias MetadataApp.{Ambientes, MotorAlta}
  alias MetadataApp.MotorAlta.Estado

  @shortdoc "Qué imagen corre en cada canal/sistema, en una sola corrida (SPEC-SYS-1809202603)"

  @moduledoc """
  Uso: mix motor.estado_extension <ambiente>

  Consulta, de una sola corrida, qué imagen corre AHORA MISMO en los 3
  canales (`unstable`/`testing`/`stable`) y en cada cliente de
  `priv/sistemas.json` -- el tag de cada imagen ya ES el hash de commit de
  git (`ci.yml` tagea `:${{ github.sha }}` en cada build), directamente
  correlacionable contra `git log`/GitHub sin ningún esquema de versión
  aparte (R4).

  `<ambiente>` -- explícito siempre, mismo criterio que
  `mix motor.propagar_extension`: nunca infiere a qué servidor SSH
  conectarse, aunque hoy en la práctica exista un solo ambiente relevante
  (todos los canales y clientes viven en el mismo clúster).

  Un destino puntual que falla (SSH caído, deployment inexistente) se
  muestra como error en SU fila, sin ocultar el resultado de los demás
  (R5).
  """

  def run(args) do
    Mix.Task.run("app.config")

    case args do
      [nombre_ambiente] -> estado(nombre_ambiente)
      _ -> Mix.raise("Uso: mix motor.estado_extension <ambiente>")
    end
  end

  defp estado(nombre_ambiente) do
    {:ok, _pid} = MetadataApp.Vault.start_link([])

    {:ok, ambiente, _apps} =
      Ecto.Migrator.with_repo(MetadataApp.Repo, fn _repo -> Ambientes.obtener_ambiente_por_nombre(nombre_ambiente) end)

    case ambiente do
      nil ->
        Mix.raise("No existe ningún ambiente \"#{nombre_ambiente}\".")

      ambiente ->
        resultados = Estado.consultar_todo(ambiente)
        {canales, sistemas} = Enum.split_with(resultados, &(&1.tipo == :canal))

        Mix.shell().info("== canales ==")
        Enum.each(Enum.sort_by(canales, & &1.destino), &mostrar_fila/1)

        Mix.shell().info("\n== sistemas (priv/sistemas.json) ==")

        case sistemas do
          [] -> Mix.shell().info("  (ninguno registrado)")
          _ -> Enum.each(Enum.sort_by(sistemas, & &1.destino), &mostrar_fila/1)
        end
    end
  end

  defp mostrar_fila(%{destino: destino, resultado: {:ok, imagen}}) do
    Mix.shell().info("  #{destino}: #{imagen}")
  end

  defp mostrar_fila(%{destino: destino, resultado: {:error, mensaje}}) do
    Mix.shell().info("  #{destino}: [ERROR] #{mensaje}")
  end
end
