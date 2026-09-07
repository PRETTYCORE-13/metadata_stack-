# SPEC-SYS-0309202601 — Alta de Sistema Nuevo

**Documento:** Tasks · **Fase:** 🚧 en construcción (2026-09-03).

Orden pensado para que cada grupo sea verificable antes de enganchar el
siguiente: primero el Postgres compartido y el mecanismo de alta probado
contra un sistema de mentira, después lo que toca CI/CD compartido, y solo
al final las acciones reales sobre sistemas de producción existentes
(recrear `metadata-stack-app` como `metadata-unstable`, dar de alta el
primer cliente de verdad).

## Grupo A — "aws-postgres" compartido en k3s (R2) ✅ (reemplaza el plan original)

**Cambio de plan ejecutado 2026-09-04** (ver `design.md` §2,
`requirements.md` R2 corregido): en vez de un `docker-compose` local por
developer, se armó UN servidor Postgres compartido dentro del mismo k3s —
reemplazó a un contenedor Docker Swarm suelto (`aws_postgres`, stack `aws`)
que ya existía sin datos de valor.

1. [x] Baja del stack Swarm viejo — `docker stack rm aws` (sin datos que
   perder, confirmado antes de borrar).
2. [x] `aws-postgres` — `StatefulSet` + `Service` (ClusterIP, sin puerto al
   host) + `Secret` con credenciales nuevas, namespace `metadata-stack`,
   volumen persistente 10Gi (`local-path`).
3. [x] Verificado: pod `Running`, responde `psql` (Postgres 16.15).
4. [x] **Hallazgo real de la ejecución**: el nodo tenía el taint
   `disk-pressure` (84% de disco) — bloqueaba programar el pod nuevo, sin
   relación a este spec. Se liberó con `docker image prune -f` (9.3GB,
   solo imágenes sin taggear). El taint tarda ~5 min en soltarse después de
   que el disco mejora (período de transición de kubelet).
5. [x] `priv/sistemas.json` — creado, `{}`.
6. [x] Verificación manual — `CREATE DATABASE db_prueba` a mano contra
   `aws-postgres-0`, conectado desde OTRO pod (`kubectl run` efímero,
   `postgres:16`) vía `aws-postgres:5432` — confirmado
   `current_database: db_prueba`. Base de prueba borrada después
   (`DROP DATABASE`), no queda residuo en el servidor compartido.

**Grupo A cerrado.**

## Grupo B — `mix motor.alta` contra `aws-postgres` (R1, R3, R4)

7. [x] `mix motor.alta <sistema>` — paso de validación (§4 punto 1):
   `MetadataApp.MotorAlta.validar_nombre/2` (charset RFC 1123 + no
   registrado en `priv/sistemas.json`), mix task como interfaz fina.
   [`motor_alta.ex`](../../../lib/metadata_app/motor_alta.ex),
   [`motor.alta.ex`](../../../lib/mix/tasks/motor.alta.ex),
   [`motor_alta_test.exs`](../../../test/metadata_app/motor_alta_test.exs)
   — 8 tests, contra un archivo temporal (nunca el `sistemas.json` real).
   Sin SSH todavía, como estaba previsto.
8. [x] Paso 2 (§4) — `MotorAlta.crear_base/2`, SSH (`MetadataApp.Ssh`, mismo
   mecanismo que `mix motor.desplegar`) contra el ambiente "Metadata" ->
   `kubectl exec` sobre `aws-postgres-0` -> `CREATE DATABASE "db_<sistema>"`
   (comillas dobles: `<sistema>` puede tener guiones, sin comillas rompe).
   Verificado real, `{:ok, "CREATE DATABASE\n"}`, base de prueba borrada
   después.

   **Hallazgo real, importante para cualquiera que corra esto**:
   `MetadataApp.Ssh`/`System.cmd` es **poco confiable corriendo directo
   en Windows** (cuelga, o vuelve con la salida vacía aunque el comando
   remoto sí falló) — no es un bug de este código, es specific de cómo
   Erlang maneja el proceso `ssh.exe` nativo de Windows vía pipes.
   **Confirmado que funciona bien y rápido desde Linux** (el devcontainer,
   mismo ambiente que usa CI) — `mix motor.alta` hay que correrlo desde
   ahí, no directo en una terminal de Windows. También arreglado en el
   camino: el ambiente "Metadata" tenía guardado el dominio
   `metadata.ventaenruta.com.mx`, que ahora resuelve a Cloudflare
   (proxied) y no deja pasar SSH — usa la IP directa por ahora
   (infraestructura está armando `ssh.ventaenruta.com.mx`, DNS-only, para
   reemplazarla más adelante), y quedó configurado con llave privada en
   vez de la contraseña vieja que tenía guardada (no se pudo confirmar si
   esa contraseña seguía siendo válida).
9. [x] Paso 3 (§4) — `MotorAlta.manifiestos_k3s/2` genera el YAML de los 4
   recursos (Secret propio con `SECRET_KEY_BASE`/`CLOAK_KEY` frescos +
   `DB_NAME_PSQL`/`PHX_HOST` derivados, Service, Deployment, Ingress).
   `imagen` es siempre explícita (nunca `:latest` por default — un
   sistema de cliente arranca en lo que hoy corre en Stable, mismo
   principio que R6). Las credenciales de `aws-postgres` se referencian
   vía `secretKeyRef` a `aws-postgres-env` (nunca copiadas a un Secret
   nuevo). Verificado con `kubectl apply --dry-run=client` Y
   `--dry-run=server` contra el clúster real — los 4 recursos pasan
   validación de esquema sin crear nada. 4 tests nuevos (sin más
   dependencias que el propio módulo).

   **Dependencias que este manifiesto asume y todavía NO existen**
   (anotado en el moduledoc, no bloquea esta tarea): el Secret
   `smtp-compartido` (credenciales reales de correo, hace falta crearlo
   una sola vez, a mano) y `wildcard-ventaenruta-tls` (Grupo F, tarea 24).

   **Detour real, no relacionado a esta tarea**: para poder correr
   `mix test` en el devcontainer hubo que migrar esa base desde cero por
   primera vez, lo que pegó contra ~13 migraciones históricas con
   problemas de orden ya documentados (mismo patrón de recuperación de
   siempre — saltarlas insertando el registro en `meta_schema_migrations`
   y reintentar). Los tests de este módulo no necesitan `meta.import`/
   `gen.catalogos` para nada, así que no hizo falta terminar esa parte.
10. [x] Paso 4 (§4) — `MotorAlta.aplicar_manifiestos/3`: base64 del YAML
    embebido en un solo script SSH (mismo motivo que
    `MetaPublicador.disparar_deploy/2` -- `MetadataApp.Ssh` no permite
    pipear stdin), `kubectl apply` + `rollout status` + pod más nuevo por
    `creationTimestamp` (mismo fix real de `ci.yml`) + `bin/setup`.
    Verificado real contra k3s: pod arriba, `bin/setup` corre.

    **Hallazgo mayor, no planeado, resuelto en esta misma tarea (2026-09-04):**
    la primera corrida real reveló que **cualquier sistema nuevo real
    fallaba `bin/setup`** -- el historial de migraciones nunca se había
    probado desde una base 100% vacía (todo sistema real se fue armando
    incremental). Auditoría completa, migrando desde cero repetidas veces
    y arreglando cada punto real encontrado:
    - 83 migraciones con timestamp viejo de 17 dígitos (milisegundos,
      previo al fix de `CatalogoGenerador.timestamp_utc/0`) ordenaban mal
      en un replay desde cero -- Ecto ordena por valor numérico, y 17
      dígitos siempre es más grande que 14, sin importar la fecha real.
      75 de esas 83 no sobreviven al schema final (se crean y se borran
      dentro del mismo bloque, no importa el orden); las que sí
      sobreviven (`pty_dsd_empleados_funcion`, `pty_gasto_diariov2`,
      `pty_aly_marcas`) se arreglaron quitando la FK problemática o
      moviendo la columna a la migración correcta -- nunca renombrando
      versiones ya aplicadas (seguro para sistemas reales, Ecto marca por
      versión, no por contenido).
    - `pty_subtipos_transaccion` tenía DOS migraciones creando la misma
      tabla (una mía, backdateada a propósito en la sesión de CI de este
      mismo día; otra real del BPB) -- la real pasó a no-op, la mía ganó
      el índice que le faltaba.
    - `pty_folio_perfiles`: dos migraciones de ago quedaron obsoletas por
      la consolidación ya hecha (2026-09-03) -- no-op.
    - `MetaImportExport.importar_meta/1` solo ordenaba maestro-antes-que-
      detalle -- un catálogo con campo "referencia" a OTRO catálogo sin
      esa relación (ej. `pty_dsd_cs_clientes` -> `pty_dsd_dsd_fac_rfc`)
      podía importarse en el orden equivocado y tumbar TODO lo que venía
      después en la lista (`Enum.map` corta ante la primera excepción).
      Ahora ordena topológicamente por las dos relaciones (maestro Y
      referencia); cuando hay un ciclo real (`pty_dsd_empleados` <->
      `pty_dsd_empleadosdet`, se referencian mutuamente) cada catálogo se
      importa de forma independiente (`rescue`, mismo criterio que ya
      usa `Release.setup/0` un nivel más arriba) -- un catálogo roto ya
      no puede bloquear el resto. 3 tests nuevos en
      `meta_import_export_test.exs`.
    - Verificado real, dos veces, desde una base 100% vacía: migración
      completa sin NINGÚN salto manual, schema final idéntico a dev
      (las 2 diferencias que quedan están explicadas, no son bugs), 37
      catálogos importados (solo el par circular queda afuera, aislado),
      **suite completa: 493 tests, 5 properties, 0 fallos**.
    - Encontrado aparte, fuera de alcance de esta tarea: `mix
      gen.catalogos` falla por un `.ex`/`.meta.json` huérfano de
      `pty_dsd_pedidos` (migración de HOY la borra a nivel de tabla, pero
      nunca se limpiaron los archivos) -- no bloquea `bin/setup` (que no
      usa `gen.catalogos`), pendiente aparte.
11. [x] Paso 5 (§4) — `MotorAlta.registrar_sistema/2`: agrega la entrada
    (`dominio`/`alta`) a `priv/sistemas.json`, comitea y pushea — salvo
    que `sistema` sea un canal (`MotorAlta.canales/0`), que se salta
    entero sin tocar el archivo. Mix task encadena los 5 pasos completos.
    3 tests nuevos: canal no toca nada, cliente se registra de verdad
    contra un repo git temporal (bare + working copy, push real
    verificado del lado del "remoto").
12. [ ] Idempotencia (§6, mitigación de "alta parcial") — correr
    `mix motor.alta` dos veces seguidas con el mismo nombre no falla ni
    duplica nada; verificar cada paso por separado.

## Grupo C — R9: defaults de negocio al completar el wizard

13. [ ] `Autenticacion.crear_empresa_para_usuario/2` extendida — dentro de
    la misma transacción, crea un Branch (`crear_branch/1`), un SalesUnit
    (`crear_sales_unit/1`) y un InventoryLocation (`crear_inventory_location/1`)
    con valores genéricos, usando el `empresa_id`/`branch_id` recién
    creados.
14. [ ] Test: completar el wizard de primer arranque deja el sistema con
    Empresa + Branch + SalesUnit + InventoryLocation, los 4 verificados
    por consulta directa (no solo que no haya error).
15. [ ] Verificar que `Release.setup/0` (camino `SYSADMIN_EMAIL` por env
    var, sin wizard) también dispara lo mismo — mismo código compartido,
    no debería hacer falta nada aparte, pero confirmarlo con un test.

## Grupo D — `pty_folio_perfiles`/`pty_subtipos_transaccion` en la alta

16. [ ] `mix motor.alta` restaura los bundles de estos dos catálogos sobre
    el sistema nuevo (mismo mecanismo que `ci.yml` restaura `bc-*`
    releases), como parte del paso 3/4 de §4 — antes de que exista
    ninguna Empresa.
17. [ ] Verificación: un sistema recién dado de alta (contra el RDS
    simulado) tiene las tablas de estos dos catálogos, con su metadata
    registrada (`meta_schema_header`/`detail`), sin necesitar ninguna
    publicación aparte de ADN.

## Grupo E — CI/CD: tres canales + workflows nuevos (§3)

18. [ ] `bc-deploy.yml` — agrega input obligatorio `sistema`, el paso SSH
    calcula namespace/deployment desde ahí en vez de los valores fijos de
    hoy.
19. [ ] `actualizar-sistema.yml` (nuevo) — SSH + `kubectl set image` +
    `rollout` + `bin/setup`, inputs `sistema` + `imagen`, ambos
    obligatorios sin default.
20. [ ] Chequeo de gate en `actualizar-sistema.yml`: si `sistema` está en
    `priv/sistemas.json` (es cliente), valida que `imagen` coincida con lo
    que corre AHORA MISMO en `metadata-stable` — rechaza si no coincide.
21. [ ] `mix motor.actualizar <sistema> <imagen>` — dispara
    `actualizar-sistema.yml` vía `gh workflow run`, mismo estilo que
    `mix motor.publicar`.
22. [ ] `mix motor.promover <origen> <destino>` — valida que el par sea
    `unstable→testing` o `testing→stable` (ningún otro), consulta la
    imagen actual de `<origen>` contra k3s (mismo mecanismo de R8), llama
    `actualizar-sistema.yml` con esa imagen sobre `<destino>`.
23. [ ] `ci.yml` — el job `deploy` se actualiza para apuntar siempre a
    `metadata-unstable` (antes `metadata-stack-app`).

## Grupo F — Acciones reales sobre el servidor (última, requiere cuidado)

24. [ ] Dar de alta `metadata-unstable`/`metadata-testing`/`metadata-stable`
    contra el servidor real, vía `mix motor.alta` ya probado en los grupos
    anteriores — reemplaza a `metadata-stack-app` (sin datos que
    preservar, confirmado por el usuario).
25. [ ] Confirmar que `metadata.ventaenruta.com.mx` deja de responder (o se
    redirige) y `unstable.ventaenruta.com.mx` sirve lo mismo que servía
    antes.
26. [ ] Certificado TLS wildcard (`*.ventaenruta.com.mx`) — cert-manager +
    DNS-01, un solo Secret TLS para los tres canales (y para cualquier
    cliente futuro).
27. [ ] Push de prueba a `main` — confirmar que `ci.yml` despliega solo a
    `metadata-unstable`, nadie más se entera.
28. [ ] `mix motor.promover unstable testing` y `testing stable` — probar
    la cadena completa una vez, a mano, antes de confiar en ella para un
    cliente real.

## Grupo G — Cierre

29. [ ] Dar de alta un sistema de cliente real de punta a punta (`mix
    motor.alta`, completar el wizard, `mix motor.actualizar` con una
    imagen que venga de `metadata-stable`) — la prueba de que todo el
    mecanismo funciona junto, no solo cada pieza por separado.
30. [ ] `docs/onboarding-nuevo-sistema.md` actualizado — ya no está
    completo/vigente después de este spec, dejarlo reflejando el mecanismo
    nuevo en vez del checklist manual de 12 pasos.
31. [ ] Este documento actualizado con cada tarea completada.
