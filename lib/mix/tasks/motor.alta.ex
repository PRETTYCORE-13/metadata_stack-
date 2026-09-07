defmodule Mix.Tasks.Motor.Alta do
  use Mix.Task
  alias MetadataApp.{Ambientes, MotorAlta}

  @shortdoc "Da de alta un sistema nuevo (base + app en k3s) -- SPEC-SYS-0309202601"

  @moduledoc """
  Uso: mix motor.alta <ambiente> <sistema> <imagen>

  Mecanismo de alta de un sistema nuevo (cliente, o uno de los tres
  canales unstable/testing/stable) -- ver
  `docs/specs/SPEC-SYS-0309202601-alta-sistema-nuevo/design.md` §4 para
  los 5 pasos completos.

  `<ambiente>` -- mismo argumento y mismo mecanismo que ya usa
  `mix motor.desplegar` (`MetadataApp.Ambientes`/`MetadataApp.Ssh`):
  parametrizado por ambiente en vez de fijo, aunque hoy exista un solo
  servidor ("Metadata") -- no vale la pena romper esa convención ya
  establecida acá.

  `<imagen>` -- siempre explícita por ahora (nunca implícita "la de
  Stable"), hasta que exista Stable de verdad (Grupo F) y tenga sentido
  derivarla sola.

  **Estado actual (Grupo B, tarea 11): los 5 pasos de §4 implementados.**
  """

  def run(args) do
    Mix.Task.run("app.config")

    case args do
      [nombre_ambiente, sistema, imagen] -> alta(nombre_ambiente, sistema, imagen)
      _ -> Mix.raise("Uso: mix motor.alta <ambiente> <sistema> <imagen>")
    end
  end

  defp alta(nombre_ambiente, sistema, imagen) do
    case MotorAlta.validar_nombre(sistema) do
      {:error, mensaje} ->
        Mix.raise(mensaje)

      {:ok, _sistema} ->
        # Mismo orden que motor.desplegar.ex: Vault ANTES de tocar el
        # Repo (necesita descifrar ssh_password/ssh_llave_privada), y
        # Ecto.Migrator.with_repo/3 en vez de Mix.Task.run("app.start")
        # para no levantar también el Endpoint.
        {:ok, _pid} = MetadataApp.Vault.start_link([])

        # exponer_dominio/3 (paso 5, más abajo) usa Req (PanelControl.Cloudflare)
        # -- sin app.start, el pool Req.Finch nunca arranca solo.
        # Encontrado real dando de alta "stable": "unknown registry:
        # Req.Finch". Liviano (no levanta Endpoint ni nada de Phoenix),
        # a diferencia de "app.start" completo.
        {:ok, _} = Application.ensure_all_started(:req)

        {:ok, ambiente, _apps} =
          Ecto.Migrator.with_repo(MetadataApp.Repo, fn _repo -> Ambientes.obtener_ambiente_por_nombre(nombre_ambiente) end)

        case ambiente do
          nil ->
            Mix.raise("No existe ningún ambiente \"#{nombre_ambiente}\".")

          ambiente ->
            Mix.shell().info("\"#{sistema}\" es un nombre válido -- verificando contra el servidor...")

            with {:ok, _sistema} <- MotorAlta.validar_no_existe_en_servidor(ambiente, sistema),
                 _ <- Mix.shell().info("todavía no está de alta."),
                 _ <- Mix.shell().info("== creando db_#{sistema} en \"#{ambiente.nombre}\" =="),
                 {:ok, salida_db} <- MotorAlta.crear_base(ambiente, sistema),
                 _ <- Mix.shell().info(salida_db),
                 _ <- Mix.shell().info("== aplicando manifiestos de k3s + bin/setup =="),
                 {:ok, nodeport, salida_k3s} <- MotorAlta.aplicar_manifiestos(ambiente, sistema, imagen),
                 _ <- Mix.shell().info(salida_k3s),
                 _ <- Mix.shell().info("== exponiendo #{sistema}.ventaenruta.com.mx (DNS + Caddy) =="),
                 {:ok, resultado_dominio, _apps} <-
                   Ecto.Migrator.with_repo(MetadataApp.Repo, fn _repo -> MotorAlta.exponer_dominio(ambiente, sistema, nodeport) end),
                 {:ok, salida_dominio} <- resultado_dominio,
                 _ <- Mix.shell().info(salida_dominio),
                 _ <- Mix.shell().info("== registrando en priv/sistemas.json =="),
                 {:ok, resultado_registro} <- MotorAlta.registrar_sistema(sistema) do
              case resultado_registro do
                :canal -> Mix.shell().info("(no se registra -- \"#{sistema}\" es un canal, no un cliente)")
                :registrado -> Mix.shell().info("registrado, comiteado y pusheado.")
              end

              Mix.shell().info("\"#{sistema}\" está de alta y arrancado -- listo para el wizard de primer arranque.")
            else
              {:error, mensaje} -> Mix.raise("Alta de \"#{sistema}\" falló:\n#{mensaje}")
            end
        end
    end
  end
end
