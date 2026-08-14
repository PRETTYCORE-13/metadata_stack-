import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/metadata_app start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :metadata_app, MetadataAppWeb.Endpoint, server: true
end

# Nombre de la empresa/tenant mostrado en la barra superior — pensado para
# blanqueo de marca a futuro: distinto deploy, distinta variable de entorno,
# sin tocar código. Vale para todos los ambientes (no solo prod), así en dev
# también se puede probar sin recompilar.
config :metadata_app, :nombre_empresa, System.get_env("NOMBRE_EMPRESA", "DemoCore Sa. de C.V")

if config_env() == :prod do
  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :metadata_app, MetadataApp.Repo,
    # ssl: true,
    hostname: System.get_env("DB_HOSTNAME_PSQL") || raise("environment variable DB_HOSTNAME_PSQL is missing"),
    port: String.to_integer(System.get_env("DB_PORT_PSQL") || "5432"),
    username: System.get_env("DB_USERNAME_PSQL") || raise("environment variable DB_USERNAME_PSQL is missing"),
    password: System.get_env("DB_PASSWORD_PSQL") || raise("environment variable DB_PASSWORD_PSQL is missing"),
    database: System.get_env("DB_NAME_PSQL") || raise("environment variable DB_NAME_PSQL is missing"),
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  # Cifra en reposo las credenciales de Integraciones (ver MetadataApp.Vault)
  # -- perder esta clave es IRRECUPERABLE, las credenciales cifradas con
  # ella quedan ilegibles para siempre. Guardarla en un gestor de secretos
  # real, con el mismo cuidado que secret_key_base de arriba.
  cloak_key =
    System.get_env("CLOAK_KEY") ||
      raise """
      environment variable CLOAK_KEY is missing.
      You can generate one with: :crypto.strong_rand_bytes(32) |> Base.encode64()
      """

  config :metadata_app, MetadataApp.Vault,
    json_library: Jason,
    ciphers: [
      default: {Cloak.Ciphers.AES.GCM, tag: "AES.GCM.V1", key: Base.decode64!(cloak_key), iv_length: 12}
    ]

  host = System.get_env("PHX_HOST") || "example.com"
  port = String.to_integer(System.get_env("PORT") || "4000")

  config :metadata_app, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :metadata_app, MetadataAppWeb.Endpoint,
    # No hay proxy reverso con TLS delante de este servidor — la app se
    # accede directo en PORT (4000) por http. Con :443/https acá (el
    # default de phx.gen.release, pensado para detrás de un proxy),
    # cualquier URL absoluta generada por el código (como el link del
    # magic-link del correo) apunta a un puerto/protocolo donde no hay
    # nada escuchando, y el usuario cae en un 400 Bad Request al hacer
    # clic. Si en el futuro se agrega HTTPS real, volver a ajustar esto.
    url: [host: host, port: port, scheme: "http"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://hexdocs.pm/bandit/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0},
      port: port
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :metadata_app, MetadataAppWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :metadata_app, MetadataAppWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  # Correo real para el magic-link de login (roadmap: acceso de usuarios
  # reales en producción) — sin esto, Swoosh.Adapters.Local (el default en
  # config.exs) "envía" a una bandeja en memoria que solo existe en dev
  # (/dev/mailbox, ni siquiera montado en prod), así que nadie recibía
  # nada. SMTP genérico (no un servicio transaccional dedicado) porque el
  # equipo ya tiene una cuenta de correo real para usar — mismo criterio
  # "falla fuerte, no silencioso" que ya usa DB_* arriba: sin estas 3
  # variables, el release ni arranca, en vez de mandar magic-links al
  # vacío sin que nadie se entere.
  smtp_relay =
    System.get_env("SMTP_RELAY") || raise("environment variable SMTP_RELAY is missing")

  config :metadata_app, MetadataApp.Mailer,
    adapter: Swoosh.Adapters.SMTP,
    relay: smtp_relay,
    username: System.get_env("SMTP_USERNAME") || raise("environment variable SMTP_USERNAME is missing"),
    password: System.get_env("SMTP_PASSWORD") || raise("environment variable SMTP_PASSWORD is missing"),
    port: String.to_integer(System.get_env("SMTP_PORT") || "587"),
    tls: :always,
    # Sin cacerts explícitos, el handshake TLS con Gmail falla
    # (:tls_failed) — Erlang no usa el trust store del SO por su cuenta,
    # hay que pasárselo. Confirmado en vivo contra smtp.gmail.com
    # (2026-07-31): sin esto el envío nunca se completaba (ni error visible
    # en logs, porque el resultado {:error, ...} se ignora en el flujo de
    # login por diseño anti-enumeración).
    tls_options: [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      server_name_indication: String.to_charlist(smtp_relay),
      depth: 3,
      # Sin esto, un relay cuyo cert solo cubre "*.hostinger.com" (sin la
      # entrada exacta "smtp.hostinger.com" en el SAN) falla con
      # {bad_cert, {hostname_check_failed, ...}} -- confirmado en vivo
      # (2026-08-14) contra smtp.hostinger.com. El chequeo de hostname por
      # default de :ssl no expande comodines de SAN (a diferencia de
      # OpenSSL/navegadores); pkix_verify_hostname_match_fun(:https) le
      # pide el mismo criterio de matching que ya usa cualquier navegador.
      # Gmail nunca lo necesitó porque su cert trae el nombre exacto.
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ],
    auth: :always,
    retries: 2

  # El remitente ("From") debe alinear con la cuenta autenticada arriba —
  # si no, Gmail (y la mayoría de relays) aceptan el envío (250 OK, por eso
  # la app no ve error) pero el mensaje falla DMARC/SPF del lado del
  # destinatario y se descarta en silencio, sin llegar ni a spam. Por
  # default usa la misma cuenta SMTP_USERNAME; SMTP_FROM es solo para el
  # caso de un alias verificado distinto.
  config :metadata_app,
    mailer_from: System.get_env("SMTP_FROM") || System.get_env("SMTP_USERNAME")
end
