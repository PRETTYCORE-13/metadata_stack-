# Onboarding de un sistema nuevo

> Este documento describía un plan (2026-08-14, cuando el bootstrap de un
> servidor nuevo tardaba horas de trabajo manual por SSH). Ese plan ya se
> construyó e implementó completo -- **SPEC-SYS-0309202601 "Alta de
> Sistema Nuevo"** (`docs/specs/SPEC-SYS-0309202601-alta-sistema-nuevo/`)
> reemplazó las Fases 0-3 de la versión anterior de este documento con un
> mecanismo real, probado en producción (2026-09-07: los tres canales
> unstable/testing/stable y un primer cliente real, "ennova", dados de
> alta de punta a punta con estos mismos pasos). Lo que sigue es el
> procedimiento real de hoy, no un plan.

## 1. Dar de alta un sistema nuevo

Desde el **devcontainer** (Linux) -- `MetadataApp.Ssh` corriendo directo
en una terminal de Windows nativa es poco confiable (cuelga o pierde la
salida capturada, problema de cómo Erlang maneja el `ssh.exe` de
Windows, no del mecanismo en sí):

```
mix motor.alta <ambiente> <sistema> <imagen>
```

- `<ambiente>` -- nombre de un `MetadataApp.Ambientes.Ambiente` ya
  registrado (`/sysadmin/ambientes-deploy`) con SSH al servidor real. Hoy
  existe uno solo, `"Metadata"`.
- `<sistema>` -- minúsculas, dígitos, guiones (mismo charset que un
  subdominio). Termina siendo `<sistema>.ventaenruta.com.mx`.
- `<imagen>` -- el tag completo (`ghcr.io/prettycore-13/metadata_stack:<tag>`),
  nunca implícito. Para un cliente real, siempre la que hoy corre en
  `metadata-stable` (nunca algo que no pasó por los tres canales, R6) --
  consultala con:
  ```
  kubectl get deployment/metadata-stable -n metadata-stack \
    -o jsonpath='{.spec.template.spec.containers[0].image}'
  ```

Qué hace, en orden (`lib/metadata_app/motor_alta.ex`):

1. Valida que `<sistema>` no exista ya, contra TRES fuentes:
   `priv/sistemas.json`, un Deployment `metadata-<sistema>` en k3s, y un
   bloque para ese dominio en el Caddyfile remoto -- las tres pueden
   desincronizarse entre sí (encontrado real: un sistema de otra feature,
   Panel Control, ocupando un dominio sin aparecer en las primeras dos).
2. Crea `db_<sistema>` en el Postgres compartido ("aws-postgres", un
   StatefulSet de k3s -- simula lo que eventualmente será RDS).
3. Aplica el Deployment + Service (`NodePort`) + Secret del sistema en
   k3s, y corre `/app/bin/setup` (migra + importa metadata de catálogos
   publicados) sobre el pod nuevo.
4. Expone el dominio de verdad: registro DNS tipo A en Cloudflare +
   bloque en el Caddyfile remoto apuntando al NodePort recién asignado
   (Caddy es el único front-door del servidor en 80/443, con HTTPS
   automático por dominio -- no hay Ingress de k3s ni cert-manager, ver
   §3 abajo).
5. Si `<sistema>` es un cliente (no un canal): agrega la entrada a
   `priv/sistemas.json`, comitea y pushea.

Todos los pasos son **idempotentes** -- si el proceso corta a mitad (una
migración falla, se corta la conexión), correr el mismo comando de nuevo
retoma donde quedó en vez de duplicar o fallar.

## 2. Completar el primer arranque

Con el sistema de alta, abrir `https://<sistema>.ventaenruta.com.mx` --
redirige solo a `/primer-arranque` (todavía no hay ningún sysadmin). Ahí
se completa un formulario real (email + contraseña del administrador,
nombre de la empresa) desde el navegador -- sin SSH, sin `docker exec`.
Al enviarlo, además del sysadmin y la Empresa, deja creados una Sucursal,
un Almacén y una Unidad de Venta por default (R9).

Esa pantalla desaparece para siempre en cuanto existe un sysadmin -- no
se puede volver a usar para crear uno segundo.

## 3. Por qué Caddy + Cloudflare, no Ingress/cert-manager

El plan original de esta spec asumía un ingress controller + cert-manager
en k3s con un certificado wildcard compartido. Verificado real
(2026-09-07, antes de tocar producción): el clúster no tiene ninguno de
los dos instalado. El mecanismo real, en producción desde 2026-08-26 (y
ya probado por otra feature, Panel Control, desde 2026-08-31) es un
contenedor Caddy corriendo *fuera* de k3s -- único front-door en 80/443
para TODO lo que corre en el servidor (metadata_stack, Chatwoot, Panel
Control), con HTTPS automático por dominio.

`MetadataApp.Caddy` es el módulo compartido (extraído de Panel Control)
que lee/escribe el Caddyfile remoto. Un sistema nuevo no lleva `Ingress`
-- su `Service` es `NodePort`, y Caddy le apunta directo.

## 4. Publicar/actualizar catálogos y promover entre canales

- **Publicar un catálogo de ADN a un sistema**: `mix motor.publicar
  --sistema=<sistema> <catalogo>` (o el wizard de BC List). `--sistema=`
  es obligatorio, sin default, validado contra `priv/sistemas.json`.
- **Despublicar** (un catálogo ya borrado local): `mix motor.despublicar
  --sistema=<sistema> <catalogo>`.
- **Actualizar un cliente a una imagen ya construida**: `mix
  motor.actualizar <sistema> <imagen>` -- `actualizar-sistema.yml`
  (GitHub Actions) valida que `<imagen>` sea EXACTO lo que corre ahora
  mismo en `metadata-stable`, rechaza si no. Probado real (2026-09-07,
  cliente "ennova"): acepta la imagen correcta, rechaza una inventada sin
  tocar el Deployment.
- **Promover entre canales** (`unstable→testing` o `testing→stable`,
  único par válido, nunca se saltea Testing): `mix motor.promover
  <ambiente> <origen> <destino>` -- consulta la imagen actual de
  `<origen>` por SSH y la aplica sobre `<destino>` vía el mismo
  `actualizar-sistema.yml`. Nunca hay build nuevo, solo mover el mismo
  artefacto ya construido.

`unstable` se actualiza solo, en cada push a `main` (`ci.yml`) -- es el
único canal 100% automático. `testing`/`stable` y cualquier cliente
siempre requieren un comando explícito.

## 5. Prerrequisitos que existen una sola vez (no por sistema)

- `ghcr-pull-secret` (namespace `metadata-stack`) -- credencial para
  bajar imágenes de `ghcr.io/prettycore-13`.
- `aws-postgres-env` -- credenciales del Postgres compartido.
- `smtp-compartido` -- `SMTP_RELAY`/`SMTP_USERNAME`/`SMTP_PASSWORD`/
  `SMTP_PORT` reales, compartidos por todos los sistemas.
- Una credencial de Cloudflare cargada en `/sysadmin/credenciales`
  (`sistema_externo: "cloudflare"`, token con permiso de editar DNS en la
  zona `ventaenruta.com.mx`) -- la usa `MetadataApp.PanelControl.Cloudflare`,
  compartida con Panel Control.

## 6. Setup de `gh` en el devcontainer (una sola vez por dev)

`mix motor.actualizar`/`mix motor.promover`/`mix motor.publicar` (disparan
workflows vía `gh workflow run`) y el paso final de `mix motor.alta`
(`git push` de `priv/sistemas.json`) necesitan `gh` instalado Y
autenticado dentro del devcontainer. **Resuelto (2026-09-07)**:

- `gh` ya viene instalado en la imagen del devcontainer
  (`.devcontainer/Dockerfile`, paquete `gh` de Debian trixie) -- nada que
  hacer para un devcontainer construido después de esta fecha.
- La autenticación SÍ es por dev (depende de la identidad de GitHub de
  cada uno, no se puede hornear en la imagen) -- una sola vez por
  devcontainer:
  ```
  gh auth login --hostname github.com --git-protocol https --web
  gh auth setup-git
  ```
  El primer comando imprime un código de un solo uso + una URL
  (`https://github.com/login/device`) -- completarlo en el navegador con
  la cuenta de GitHub real, después el proceso termina solo. El segundo
  configura `git` para usar `gh` como credential helper -- soluciona
  TANTO `gh workflow run` como `git push` con el mismo login, un solo
  paso. Verificar con `gh auth status` y `git push --dry-run`.

  Si el devcontainer se recrea desde cero (no solo se reinicia), hay que
  repetir el login -- la sesión de `gh` vive en `~/.config/gh/`, que no
  está en ninguno de los volúmenes persistentes de
  `.devcontainer/docker-compose.yml` hoy.

## 7. Fuera de alcance (todavía)

- Automatizar el aprovisionamiento de infraestructura del servidor en sí
  (Terraform/Ansible) -- sigue siendo manual, un solo servidor hoy.
- UI de facturación/gestión de clientes -- problema aparte de "dejar el
  sistema operativo".
