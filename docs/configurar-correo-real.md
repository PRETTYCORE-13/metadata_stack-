# Configurar un proveedor de correo real (producción)

> **Nota de seguridad:** este repo es público. La API key del proveedor **nunca va en un archivo versionado** — vive solo como variable de entorno en el servidor de producción, igual que `SECRET_KEY_BASE` o las credenciales de la base de datos. Acá vas a ver placeholders (`<api_key>`, etc.).

## Situación actual

El login es passwordless (magic link): el usuario pone su correo, la app genera un link de un solo uso y se lo "envía". Hoy ese envío usa `Swoosh.Adapters.Local` (el adapter de **desarrollo**, configurado en `config/config.exs` y nunca sobreescrito para producción en `config/runtime.exs`) — no manda nada a ningún servidor de correo real, el mensaje se pierde. Por eso nadie puede entrar todavía en producción sin el rodeo manual (ver el procedimiento de acceso manual que ya quedó documentado aparte).

`config/prod.exs` ya deja listo el cliente HTTP (`config :swoosh, api_client: Swoosh.ApiClient.Req`) — con `req` ya como dependencia (`mix.exs`), cualquiera de los adapters de API que trae Swoosh incluido funciona sin agregar paquetes nuevos. Solo falta **elegir un proveedor, conseguir una API key, y completar la config real en `config/runtime.exs`**.

## Comparación de proveedores

| Proveedor | Free tier | Setup | Notas |
|---|---|---|---|
| **Resend** | 100/día, 3,000/mes | Muy simple, API moderna | Recomendado para este proyecto — foco en devs, buena entrega, dashboard claro |
| **Mailgun** | 100/día (con tarjeta) | Simple | Veterano, confiable, algo más burocrático para verificar dominio |
| **SendGrid** | 100/día | Medio | Dashboard más pesado, pensado para marketing además de transaccional |
| **Postmark** | 100 de prueba, después de pago | Simple | Excelente entregabilidad, pero sin free tier permanente |
| **SMTP propio** (Gmail, hosting, etc.) | Depende | El más manual | Requiere `{:gen_smtp, "~> 1.0"}` extra en `mix.exs` (los demás no) — usar solo si ya tenés un SMTP confiable a mano |

**Recomendación: Resend.** Free tier generoso para el volumen de este proyecto, setup rápido (verificar dominio + un API key), y Swoosh lo soporta nativo (`Swoosh.Adapters.Resend`).

## Pasos (con Resend — adaptar si eligen otro)

### 1. Crear cuenta y verificar el dominio

1. Crear cuenta en [resend.com](https://resend.com).
2. Agregar el dominio real desde el que se van a mandar los correos (ej. `prettycore.xyz`) — **no** uses un dominio gratuito de prueba para producción de verdad, algunos clientes de correo lo marcan como spam.
3. Resend da 2-3 registros DNS (SPF, DKIM, a veces DMARC) para agregar en el proveedor de dominio. Sin esto verificado, los correos salen pero muchas bandejas los rechazan o los mandan a spam.
4. Esperar a que el dominio quede "Verified" en el dashboard (puede tardar minutos u horas según el DNS).

### 2. Generar la API key

Dashboard → API Keys → Create API Key. Copiarla — no se vuelve a mostrar completa después.

### 3. Agregar la API key al servidor de producción

Por SSH al servidor (`reiayanami.mine.nu`), agregar la variable de entorno al servicio sin recrearlo:

```bash
docker service update --env-add RESEND_API_KEY=<api_key> metadata_stack_app
```

Esto reinicia el contenedor con la variable nueva disponible — no hace falta un deploy completo solo por esto.

### 4. Código: completar `config/runtime.exs`

Reemplazar el bloque comentado de ejemplo (busca "## Configuring the mailer") por:

```elixir
config :metadata_app, MetadataApp.Mailer,
  adapter: Swoosh.Adapters.Resend,
  api_key: System.fetch_env!("RESEND_API_KEY")
```

`System.fetch_env!/1` (no `get_env/2`) a propósito — si falta la variable, la app no debería arrancar en producción pensando que el correo "funciona" cuando en realidad está silenciosamente en `Local`. Mismo criterio que ya usa este archivo para `SECRET_KEY_BASE`/`DATABASE_URL`.

También hace falta configurar el remitente (`from`) en el `deliver_usuario_*` de `lib/metadata_app/autenticacion.ex` o donde arme el `Swoosh.Email` — tiene que ser una dirección del dominio ya verificado (ej. `no-responder@prettycore.xyz`), si no Resend rechaza el envío.

### 5. Redeploy

Un push normal a `main` (el pipeline ya automático) recompila con el cambio de `runtime.exs`. No hace falta nada especial más allá del `--env-add` del paso 3, que ya quedó aplicado al servicio.

### 6. Probar de punta a punta

1. Registrar un usuario nuevo real (o pedir un magic link a uno existente) desde la app en producción.
2. Confirmar que el correo llega (revisar también spam la primera vez).
3. Si no llega: revisar el dashboard de Resend (sección "Logs" o "Emails") — ahí se ve si el proveedor lo rechazó (dominio no verificado, remitente inválido) o si sí lo entregó y el problema es otro.

## Si eligen otro proveedor en vez de Resend

Mismo patrón, cambia el `adapter` y las claves de config:

```elixir
# Mailgun
config :metadata_app, MetadataApp.Mailer,
  adapter: Swoosh.Adapters.Mailgun,
  api_key: System.fetch_env!("MAILGUN_API_KEY"),
  domain: System.fetch_env!("MAILGUN_DOMAIN")

# SendGrid
config :metadata_app, MetadataApp.Mailer,
  adapter: Swoosh.Adapters.Sendgrid,
  api_key: System.fetch_env!("SENDGRID_API_KEY")

# Postmark
config :metadata_app, MetadataApp.Mailer,
  adapter: Swoosh.Adapters.Postmark,
  api_key: System.fetch_env!("POSTMARK_API_KEY")

# SMTP propio (requiere agregar {:gen_smtp, "~> 1.0"} a mix.exs)
config :metadata_app, MetadataApp.Mailer,
  adapter: Swoosh.Adapters.SMTP,
  relay: System.fetch_env!("SMTP_RELAY"),
  username: System.fetch_env!("SMTP_USERNAME"),
  password: System.fetch_env!("SMTP_PASSWORD"),
  port: 587
```

Ver [hexdocs.pm/swoosh](https://hexdocs.pm/swoosh/Swoosh.html#module-installation) para la lista completa de adapters y sus opciones exactas.
