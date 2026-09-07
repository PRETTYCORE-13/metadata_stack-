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
12. [x] Idempotencia (§6, mitigación de "alta parcial") — verificado paso
    por paso:
    - Paso 1 (validar): ya rechazaba una alta ya completa (registrada en
      `sistemas.json`); una alta PARCIAL (interrumpida antes del paso 5)
      sigue pasando la validación tal cual, para poder retomarla.
    - Paso 2 (`crear_base`): "database already exists" ahora es éxito,
      no error. Verificado real contra `aws-postgres`: segunda corrida
      con la misma base, `{:ok, "... ya existía (alta retomada) ..."}`.
    - Pasos 3-4 (`aplicar_manifiestos`): ya eran idempotentes sin
      cambios -- `kubectl apply` actualiza en vez de fallar, `bin/setup`
      (migrar + import) también lo es por diseño.
    - Paso 5 (`registrar_sistema`): si `sistema` ya está en el archivo,
      no reescribe ni vuelve a comitear -- solo reintenta el push (nunca
      arma un commit vacío, que git rechaza con "nothing to commit").
      Test real con git (bare + working copy): registrar el mismo
      sistema dos veces deja UN solo commit en el remoto, no dos.
    - Suite completa: 497 tests, 5 properties, 0 fallos.

**Grupo B cerrado — los 5 pasos de `mix motor.alta` completos y
verificados reales, incluida la idempotencia.**

## Grupo C — R9: defaults de negocio al completar el wizard

13. [x] **Corrección de diseño real, no `crear_empresa_para_usuario/2`
    extendida como decía el plan original** — esa función es GENERAL
    (también la usa `EmpresasLive`, la pantalla de admin "Crear empresa"
    de un sistema YA en marcha, y `dev_auto_login.ex`), no exclusiva del
    wizard. Extenderla directo rompió 5 tests que asumían que no crea
    nada más que la Empresa (`JerarquiaOperativaTest`,
    `JerarquiaOrganizacionalLiveTest`, `JerarquiaOrganizacionalTest`) --
    encontrado real corriendo la suite completa, no solo el test nuevo.
    Arreglado: `crear_empresa_para_usuario/2` queda EXACTAMENTE como
    estaba; se agregó `crear_empresa_inicial_con_estructura/2` (mismo
    bloque común vía un helper privado, `extra.(empresa)` corre en la
    MISMA transacción) que sí crea Branch/SalesUnit/InventoryLocation
    genéricos -- y solo el wizard (`primer_arranque.ex`) y
    `Release.asegurar_empresa_inicial/0` la llaman.
14. [x] Test real: completar el wizard (`primer_arranque_test.exs`,
    extendido) deja el sistema con Empresa + Branch + SalesUnit +
    InventoryLocation, los 4 verificados por consulta directa.
15. [x] `Release.setup/0` (camino `SYSADMIN_EMAIL`, sin wizard) verificado
    con test real (`release_test.exs`, nuevo) -- mismo resultado, sin
    código aparte (llama a la misma función nueva). `Ecto.Migrator.with_repo/3`
    corre fuera del sandbox de test -- limpieza manual explícita en
    `on_exit`, verificada sin residuo. **Hallazgo aparte, no bloqueante**:
    `import_meta` (dentro de `setup/0`) advierte por una transición de
    `pty_dsd_cs_canales` con el mismo tipo de problema de orden ya
    arreglado para `.meta.json` (Grupo B), pero en `.motor.json`
    (`importar_motor`/`importar_catalogo_motor`) -- no bloquea `setup/0`
    (ya tolera este tipo de fallo), pendiente de arreglar aparte.
    Suite completa: 498 tests, 5 properties, 0 fallos.

**Grupo C cerrado.**

## Grupo D — `pty_folio_perfiles`/`pty_subtipos_transaccion` en la alta

16. [x] **Cerrado por verificación, no por código nuevo (2026-09-07).**
    El plan original (restaurar un bundle, como `ci.yml` con los `bc-*`
    de ADN) quedó obsoleto: la sesión de CI del 2026-09-03 ya dejó
    commiteadas de forma permanente las migraciones de estos dos
    catálogos, incluida una migración de DATOS que registra su metadata
    completa (header/detail, y estados/transiciones para
    `pty_subtipos_transaccion`) directo en código Elixir. Ver
    `design.md` §5, corrección 2026-09-07.
17. [x] Verificación real: una base migrada 100% desde cero (la misma
    auditoría del Grupo B) ya tiene `pty_folio_perfiles` y
    `pty_subtipos_transaccion` con su metadata en `meta_schema_header`,
    sin ningún paso extra — `bin/setup` (que `mix motor.alta` ya llama en
    el paso 4) alcanza solo.

**Grupo D cerrado.**

## Grupo E — CI/CD: tres canales + workflows nuevos (§3)

18. [x] `bc-deploy.yml` — agrega input obligatorio `sistema`, el paso SSH
    calcula namespace/deployment desde ahí en vez de los valores fijos de
    hoy. **Ripple obligado (R5/R6):** con `sistema` ahora requerido en el
    workflow, cada disparador tenía que empezar a mandarlo — se tocaron
    `MetaPublicador.disparar_deploy/3` (antes `/2`), `mix motor.publicar`
    y `mix motor.despublicar` (ambos con `--sistema=` obligatorio,
    validado contra `priv/sistemas.json` antes de armar nada), y el
    wizard de BC List (`bc_list_live.ex`): selector `<select>` de sistema
    en los modales de publicar/despublicar, botón de confirmar
    deshabilitado hasta elegir uno. Cobertura: `mix test` completo (498
    tests, 0 failures) + revisión directa; se intentó cubrir el selector
    del wizard con 2 tests de LiveView nuevos pero se descartaron — el
    checkbox de selección de catálogo en el árbol depende de
    `MetaEstadosAdmin.puede_desplegar?/1` (catálogo completo: campos +
    estados + transición inicial), que ningún fixture de este archivo de
    test arma hoy; construir uno solo para esto era una inversión fuera
    de alcance de esta tarea.
19. [x] `actualizar-sistema.yml` (nuevo) — SSH + `kubectl set image` +
    `rollout` + `bin/setup`, inputs `sistema` + `imagen`, ambos
    obligatorios sin default. Sin build/checkout de código (a diferencia
    de `bc-deploy.yml`) — la imagen ya existe, solo se re-apunta el
    Deployment.
20. [x] Chequeo de gate en `actualizar-sistema.yml`: si `sistema` está en
    `priv/sistemas.json` (es cliente), valida que `imagen` coincida con lo
    que corre AHORA MISMO en `metadata-stable` — rechaza si no coincide.
    El chequeo "¿es cliente?" lee `priv/sistemas.json` directo del
    checkout del propio workflow (no necesita SSH para eso — un canal
    nunca aparece ahí, §3); la comparación de imagen sí es SSH real contra
    `metadata-stable` en k3s (nunca un valor cacheado).
21. [x] `mix motor.actualizar <sistema> <imagen>` — dispara
    `actualizar-sistema.yml` vía `gh workflow run`, mismo estilo que
    `mix motor.publicar`. Valida `<sistema>` contra
    `MotorAlta.sistema_registrado?/1` antes de disparar nada (mismo
    criterio R5/R6 que `motor.publicar`/`motor.despublicar`) — el gate
    real de la imagen vive en el workflow (tarea 20), acá solo se
    descartan nombres que ni siquiera son un cliente de alta.
22. [x] `mix motor.promover <ambiente> <origen> <destino>` — valida que el
    par sea `unstable→testing` o `testing→stable` (ningún otro), consulta
    la imagen actual de `<origen>` contra k3s (`MotorAlta.imagen_actual/2`,
    mismo mecanismo de R8 que ya usa `AmbientesLive` para autocompletar),
    llama `actualizar-sistema.yml` con esa imagen sobre `<destino>`.
    **Desviación de la firma original de este ítem** (`<origen>
    <destino>`, sin `<ambiente>`): consultar la imagen de `<origen>`
    necesita SSH directo, y `MetadataApp.Ambientes` es el único registro
    de credenciales que ya existe para eso — mismo motivo exacto por el
    que `mix motor.alta` ya toma `<ambiente>` como primer argumento (§4).
    Cobertura: `MotorAlta.imagen_actual/2` sin test automático (necesita
    SSH real, mismo criterio ya establecido para `crear_base`/
    `aplicar_manifiestos`); `MotorAlta.disparar_actualizacion/2` cubierto
    en `test/metadata_app/motor_alta_actualizacion_test.exs` (módulo
    aparte, `async: false`, mismo patrón PATH-vacío que
    `MetaPublicadorTest`). `mix test` completo: 499 tests, 0 failures.
23. [x] `ci.yml` — el job `deploy` se actualiza para apuntar siempre a
    `metadata-unstable` (antes `metadata-stack-app`).

**Grupo E cerrado (2026-09-07).** Falta la parte de infraestructura real
(dar de alta los tres canales de verdad en el servidor, wildcard TLS,
probar el push automático y las dos promociones de punta a punta) — eso
es Grupo F, no código nuevo.

## Grupo F — Acciones reales sobre el servidor (última, requiere cuidado)

24. [x] **Corrección real de diseño, ANTES de tocar producción (2026-09-07).**
    Recon en vivo del servidor (namespaces, `ingressclass`, `cert-manager`,
    bases en `aws-postgres`, Caddyfile remoto) encontró que el plan
    original (Ingress de k3s + cert-manager + Secret TLS wildcard) nunca
    hubiera funcionado -- el clúster no tiene ingress controller ni
    cert-manager. El mecanismo real ya en producción (desde 2026-08-26,
    probado a fondo por `MetadataApp.PanelControl` desde 2026-08-31) es
    Caddy (fuera de k3s, único front-door 80/443) + Cloudflare (DNS).
    También encontró un sistema `crm` real (Panel Control, no
    `metadata_stack`) ya ocupando `crm.ventaenruta.com.mx` -- ninguna de
    las validaciones existentes lo detectaba. Corregido:
    - `design.md` §1/§4/§6 actualizados (Service `NodePort` en vez de
      Ingress, ejemplo `acme` en vez de `crm`, riesgo de TLS reescrito).
    - `MetadataApp.Caddy` (nuevo) — extrae la lógica de
      `PanelControl.Desplegador.agregar_a_caddy/3` (leer/reemplazar
      bloque/reescribir/`caddy reload`) a un módulo compartido; Panel
      Control pasa a llamarlo en vez de duplicar el regex.
    - `MotorAlta.manifiestos_k3s/2` — Service a `NodePort`, sin recurso
      `Ingress`.
    - `MotorAlta.validar_no_existe_en_servidor/2` (nuevo) — la "segunda
      fuente" que design.md §4/§6 pedía desde Grupo B y nunca se había
      implementado, más una tercera (Caddyfile) por el hallazgo de `crm`.
    - `MotorAlta.exponer_dominio/3` (nuevo) — DNS (Cloudflare) + Caddy,
      llamado por `mix motor.alta` entre "aplicar manifiestos" y
      "registrar en sistemas.json".
    Cobertura: `MetadataApp.CaddyTest` (la parte pura,
    `contenido_con_bloque/3`, sin SSH); `manifiestos_k3s/2` re-testeado
    sin Ingress; `validar_no_existe_en_servidor/2`/`exponer_dominio/3`
    sin test automático (SSH real, mismo criterio que `crear_base`/
    `aplicar_manifiestos`). `mix test` completo antes de seguir.
25. [x] **Dado de alta real (2026-09-07)**: `metadata-unstable`/
    `metadata-testing`/`metadata-stable` existen de verdad en el servidor
    (`mix motor.alta Metadata <canal> ghcr.io/prettycore-13/metadata_stack:latest`
    para los tres). En el camino, dar de alta el primer canal real
    ("unstable") destapó una cadena de bugs preexistentes que bloqueaban
    CUALQUIER alta nueva (no algo de esta spec, algo que esta spec fue la
    primera en ejercitar de verdad) -- todos encontrados y arreglados en
    el momento, cada uno su propio commit:
    - CI rompía desde cero (`mix ecto.migrate`) por una columna duplicada
      en `pty_dsd_empleados` -- faltaban 2 migraciones "quitar" intermedias
      sin comitear entre dos ya fixeadas en la auditoría del 2026-09-04.
    - 3 bundles `bc-*` publicados ANTES de esa misma auditoría
      (`bc-pty_dsd_pedidos_items`, `bc-pty_gasto_diariov2`,
      `bc-pty_aly_marcas`) tenían copias VIEJAS de migraciones ya
      fixeadas en git -- `ci.yml` las restauraba en cada deploy,
      resucitando el bug ya arreglado. `bc-pty_dsd_pedidos_items`
      además le faltaba el catálogo `pty_dsd_mat_material` del que
      dependía (publicado sin sus referencias, catálogo mismo ya no
      existe -- se despublicó nunca corriendo `mix motor.despublicar`).
      Los 3 releases se re-subieron con bundle corregido.
    - `mix motor.alta` perdía el Repo (necesita `Ecto.Migrator.with_repo/3`
      de nuevo) y nunca arrancaba Req (`Application.ensure_all_started(:req)`)
      antes de `exponer_dominio/3` -- 2 fixes chicos, cada uno su commit.
    - `MetadataApp.Caddy.exponer/3` confundía "stable" con "unstable"
      (substring literal sin ancla de línea) -- `validar_no_existe_en_servidor/2`
      lo frenó como falso positivo de colisión antes de escribir nada,
      pero el bug de fondo (regex sin `^`/`/m`) también se arregló.
    Verificado real: los 3 pods `Running`, migrados, HTTPS sirviendo
    "/primer-arranque". Credencial de Cloudflare cargada en la base local
    (no existía, necesaria para `PanelControl.Cloudflare`).
    `metadata-stack-app`/`metadata-stack-postgres` (Deployment+Service+
    Secret+PVC, el hallazgo del recon original) borrados -- reemplazados
    por los 3 canales.
26. [x] Confirmado real: `metadata.ventaenruta.com.mx` devuelve 525 (sin
    bloque en Caddy, ya no hay nada ahí) tras sacar su entrada del
    Caddyfile; `unstable`/`testing`/`stable`.ventaenruta.com.mx sirven
    con HTTPS válido (certificado automático de Caddy, sin wildcard ni
    intervención manual).
27. [x] Ya verificado en el camino de la tarea 25 (varios pushes reales a
    `main` durante el fix de CI) -- `ci.yml` despliega solo a
    `metadata-unstable`, `testing`/`stable` nunca se tocan por un push
    normal.
28. [x] Probado real: `actualizar-sistema.yml` disparado a mano dos veces
    (`sistema=testing`/`sistema=stable`, imagen de `unstable`) -- el paso
    "Determinar si es cliente" correctamente detecta que ninguno de los
    dos está en `priv/sistemas.json` y saltea el gate (correcto, un canal
    nunca lo necesita). **Nota operativa**: `mix motor.promover` en sí no
    se pudo correr completo desde el devcontainer -- tiene `ssh` (para
    `imagen_actual/2`) pero no `gh` instalado, así que el paso de
    `disparar_actualizacion/2` falló con `:enoent`; se completó disparando
    `actualizar-sistema.yml` a mano desde la laptop de Dev (que sí tiene
    `gh` autenticado) con la imagen que `mix motor.promover` ya había
    impreso. Instalar `gh` en el devcontainer queda pendiente, no es un
    bug de código.

**Grupo F cerrado (2026-09-07).** Los tres canales existen de verdad en
producción, migrados, expuestos con HTTPS real, y la promoción entre
ellos está probada. Falta Grupo G: un cliente real de punta a punta.

## Grupo G — Cierre

29. [x] **Cliente real dado de alta de punta a punta (2026-09-07): "ennova"**
    (`ennova.ventaenruta.com.mx`). `mix motor.alta Metadata ennova
    ghcr.io/prettycore-13/metadata_stack:latest` (misma imagen que corre
    hoy en `metadata-stable`, R6) -- verificado real: DB creada, pod
    migrado, DNS + Caddy expuestos, HTTPS válido, redirige a
    `/primer-arranque`. Registrado de verdad en `priv/sistemas.json`
    (commiteado y pusheado). El wizard de primer arranque queda para que
    el usuario lo complete desde el navegador con credenciales reales de
    sysadmin -- no es algo que este mecanismo deba automatizar.

    `mix motor.actualizar ennova <imagen-de-stable>` probado dos veces
    contra `actualizar-sistema.yml` real: con la imagen correcta, el gate
    de cliente (que hasta ahora solo se había visto SALTEADO para
    unstable/testing, nunca corrido de verdad) pasó y actualizó
    `metadata-ennova`; con una imagen inventada, el gate lo RECHAZÓ antes
    de tocar el Deployment -- primera verificación real de que ese
    control de seguridad funciona.

    **Hallazgo operativo nuevo**: `MotorAlta.registrar_sistema/2` (el
    `git push` de `priv/sistemas.json`) no funciona corriendo `mix
    motor.alta` desde el devcontainer -- no tiene credenciales de git
    configuradas para el remoto HTTPS (`fatal: could not read Username`).
    El commit local se arma bien (limpio, solo ese archivo); hubo que
    empujarlo a mano desde la laptop de Dev. Mismo tipo de gap que "gh no
    instalado en el devcontainer" (tarea 28) -- pendiente de resolver
    antes de que ADN pueda dar de alta un cliente sin depender de que Dev
    haga el push a mano.
30. [ ] `docs/onboarding-nuevo-sistema.md` actualizado — ya no está
    completo/vigente después de este spec, dejarlo reflejando el mecanismo
    nuevo en vez del checklist manual de 12 pasos.
31. [ ] Este documento actualizado con cada tarea completada.
