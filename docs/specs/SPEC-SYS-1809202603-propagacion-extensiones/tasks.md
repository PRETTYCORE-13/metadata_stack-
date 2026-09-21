# SPEC-SYS-1809202603 — Propagación de Extensiones (CORE)

**Documento:** Tasks · **Fase:** 🟡 borrador, en discusión con el usuario (2026-09-18).

Orden pensado para que cada grupo sea verificable de punta a punta
antes de seguir con el siguiente (regla del skill `spec`: ejecutar,
mostrar, esperar) — nada de código empieza sin que `requirements.md` Y
`design.md` estén aprobados (ya lo están).

## Grupo A — Renombrar los comandos existentes (R1-R3) ✅

1. [x] `git mv lib/mix/tasks/motor.promover.ex
   lib/mix/tasks/motor.propagar_extension.ex` — módulo renombrado
   `Mix.Tasks.Motor.Promover` → `Mix.Tasks.Motor.PropagarExtension`,
   `@shortdoc`, uso en `@moduledoc`, mensajes `Mix.shell().info`/
   `Mix.raise`.
2. [x] `git mv lib/mix/tasks/motor.actualizar.ex
   lib/mix/tasks/motor.propagar_extension_a_sistema.ex` — mismo
   renombrado, queda `Mix.Tasks.Motor.PropagarExtensionASistema`.
3. [x] Grep de `motor.promover`/`motor.actualizar` en todo el repo —
   actualizadas las menciones reales: `SPEC-SYS-0309202601/design.md`
   §3 (dos bloques + 2 menciones sueltas), `motor.publicar.ex` (2
   comentarios), `motor_alta.ex` (2 comentarios), `actualizar-sistema.yml`
   (3 comentarios), `ci.yml` (1 comentario), `.devcontainer/Dockerfile`
   (1 comentario), `docs/onboarding-nuevo-sistema.md` (3 menciones).
   `SPEC-SYS-0309202601/requirements.md` R10 no citaba el nombre
   literal — sin cambios ahí. `SPEC-SYS-0309202601/tasks.md` (histórico,
   ✅ implementado) se dejó SIN TOCAR a propósito — es un registro de
   comandos reales ya ejecutados en su momento, renombrarlo falsificaría
   la historia.
4. [x] `mix compile` limpio (sin errores; los warnings presentes son
   preexistentes, no relacionados — confirmado con grep dirigido a los
   dos archivos nuevos).
5. [x] Verificación real en dev: `mix motor.propagar_extension` y
   `mix motor.propagar_extension_a_sistema` sin argumentos muestran el
   uso con el nombre nuevo; `mix motor.promover`/`mix motor.actualizar`
   ya no existen (`could not be found`). `mix test`: 647/649 (2 fallas
   preexistentes sin relación, mismas de siempre).

## Grupo B — `mix motor.estado_extension` (R4-R5) ✅

> **Fork resuelto con el usuario antes de implementar** (design.md no
> especificaba cómo resolver el `%Ambiente{}` SSH): `<ambiente>`
> argumento explícito, mismo criterio que `motor.propagar_extension` —
> nunca infiere. `design.md` §2 actualizado con esta decisión.

6. [x] `lib/metadata_app/motor_alta/estado.ex` — `consultar_todo/2`
   (`ambiente`, `dependencias \\ {canales/0, leer_sistemas/0, imagen_actual/2}`
   inyectables, mismo criterio que `path \\ ruta_sistemas()` del resto
   de `MotorAlta`), `Task.async_stream/3` con `on_timeout: :kill_task`,
   cada resultado `%{destino:, tipo:, resultado:}` — un error o
   excepción de un destino puntual (`rescue` en `consultar_uno/3`) no
   aborta a los demás.
7. [x] `lib/mix/tasks/motor.estado_extension.ex` — toma `<ambiente>`,
   tabla de texto canales primero (orden alfabético) + sistemas después,
   fila `[ERROR] ...` visible sin frenar el resto.
8. [x] Test `test/metadata_app/motor_alta/estado_test.exs` — 4 tests,
   dependencias inyectadas (SIN mock de SSH real -- mismo criterio ya
   establecido en `motor_alta_actualizacion_test.exs`: `imagen_actual/2`
   no tiene cobertura automática de SSH en este proyecto, se verifica
   real). Cubre: todos responden bien, un destino en error no oculta a
   los demás (R5), una excepción se captura sin abortar el resto, sin
   sistemas registrados solo devuelve los 3 canales.
9. [x] Verificación real: `mix motor.estado_extension Metadata` en dev --
   los 4 destinos (3 canales + `ennova`) fallaron cada uno por separado,
   con su propio mensaje, sin que ninguno ocultara a los demás -- R5
   demostrado en vivo. **Dos hallazgos reales encontrados y corregidos
   aparte, fuera de esta spec** (ver nota debajo de Grupo C): (1) la
   llave SSH guardada tenía passphrase -- se generó una llave nueva sin
   passphrase y se actualizó en `/sysadmin/ambientes`; (2) un bug real
   en `MetadataApp.Ssh` (preexistente, no introducido por esta spec):
   en Windows nativo, `System.cmd("ssh", ...)` resolvía al ssh de Git
   for Windows (MSYS2), que se cuelga indefinidamente al ser lanzado
   desde un proceso Win32 nativo como `erl.exe` -- corregido para usar
   el OpenSSH nativo de Windows por ruta absoluta. Con ambos arreglados,
   verificado en vivo: los 4 destinos responden con la imagen real
   (`ghcr.io/prettycore-13/metadata_stack:latest`) en segundos.

## Grupo C — Guarda de idempotencia (R6-R7) ✅

> **Fork resuelto con el usuario antes de implementar**: `design.md` §3
> asumía (incorrecto) que `mix motor.publicar`/`AmbientesLive` ya
> resolvían un `%Ambiente{}` por sistema -- verificado en código real
> que NO es así (el despliegue real usa 3 secrets FIJOS de GitHub
> Actions, nunca la tabla `Ambientes`), y que
> `mix motor.propagar_extension_a_sistema` no tenía ningún concepto de
> ambiente. Decisión confirmada: agregarle `<ambiente>` explícito
> también a ese comando (cambia su firma) -- única fuente real de
> credenciales SSH disponible. `design.md` §3 corregido.

10. [x] `MotorAlta.disparar_actualizacion/2` → `/4` (`ambiente`, `sistema`,
    `imagen`, `fun_imagen_actual \\ &imagen_actual/2` inyectable para
    tests) — chequeo previo contra `imagen_actual/2`, devuelve
    `{:ok, :sin_cambios, mensaje}` sin llamar a `gh workflow run` cuando
    coincide exacto.
11. [x] ~~`imagen_actual_por_nombre/1`~~ — innecesario tras la decisión de
    arriba: ambos comandos ya reciben `<ambiente>` explícito, se pasa
    directo a `imagen_actual/2`.
12. [x] `Mix.Tasks.Motor.PropagarExtension`/`PropagarExtensionASistema`
    (esta última ahora con `<ambiente>` nuevo en su firma) imprimen el
    mensaje de "sin cambios" y terminan sin error (no es un fallo).
13. [x] Tests (`motor_alta_actualizacion_test.exs`, dependencia
    inyectada, sin SSH real -- mismo criterio de siempre): destino ya en
    la imagen pedida → `:sin_cambios`, nunca llama a `gh`; destino en
    otra imagen → sigue con el disparo normal; falla la consulta →
    igual sigue con el disparo, nunca bloquea. 6 tests nuevos en total
    (3 de la guarda + firma actualizada de los 3 que ya existían).
    `mix test`: 659/661 (2 fallas preexistentes sin relación).
14. [x] Verificación real en dev: `mix motor.propagar_extension_a_sistema
    Metadata ennova ghcr.io/prettycore-13/metadata_stack:latest` (la
    imagen que YA corre ahí, confirmado con Grupo B) -- imprime el
    mensaje de "sin cambios", termina sin error, sin disparar ningún
    workflow. Desbloqueado por los dos arreglos de infra documentados
    en Grupo B tarea 9 (llave SSH nueva + fix del binario ssh en
    Windows, ver nota debajo).

> **Nota — dos hallazgos reales de infraestructura, fuera del alcance
> formal de esta spec, encontrados y corregidos en el camino de
> verificar Grupo B/C en vivo:**
> 1. La llave SSH guardada en `/sysadmin/ambientes` para "Metadata"
>    tenía passphrase (`aes256-ctr`/`bcrypt`, confirmado con
>    `ssh-keygen`) -- `MetadataApp.Ssh` no soporta llaves con
>    passphrase. Se generó un par ed25519 nuevo sin passphrase, se
>    agregó la pública a `~/.ssh/authorized_keys` del servidor
>    (167.233.84.151, usuario `elixir`) y se actualizó la privada en
>    `/sysadmin/ambientes` (vía el campo virtual
>    `ssh_llave_privada_nueva` -- pasar `ssh_llave_privada` directo NO
>    hace nada, `cast/3` lo ignora silenciosamente, error real cometido
>    y corregido en el camino).
> 2. **Bug real preexistente en `MetadataApp.Ssh`** (no introducido por
>    esta spec, pero recién ejercitado ahora porque es la primera vez
>    que una llave SSH real completa una conexión de punta a punta
>    desde la migración a Windows nativo): `System.cmd("ssh", ...)`
>    resolvía por PATH al ssh de Git for Windows (MSYS2), que se
>    CUELGA INDEFINIDAMENTE (confirmado con `Get-Process`: procesos
>    huérfanos acumulando cientos de segundos de CPU) al ser lanzado
>    desde un proceso Win32 nativo (`erl.exe`) sin consola/pty real. El
>    OpenSSH nativo de Windows no tiene ese problema. Corregido en
>    `lib/metadata_app/ssh.ex` (`binario_ssh/0`): en Windows usa la ruta
>    absoluta al OpenSSH nativo; en cualquier otro SO (producción,
>    Linux) sigue igual que antes. Verificado en vivo: las 4 consultas
>    de `mix motor.estado_extension Metadata` responden en segundos con
>    la imagen real. `mix test`: 665/667 (2 fallas preexistentes sin
>    relación).

## Grupo D — `--commit=<hash>` (R8) ✅

> **Dos hallazgos reales al confirmar el comando de `gh api` antes de
> escribir código** (principio "no asumir" del skill `spec`):
> `prettycore-13` es un USUARIO de GitHub, no una organización
> (`/orgs/...` da 404, el endpoint real es `users/prettycore-13/...`);
> y el token de `gh` de este entorno no tenía el scope `read:packages`
> por default (403 hasta que el usuario corrió
> `gh auth refresh -h github.com -s read:packages`, paso manual
> interactivo). `design.md` §4 corregido con el comando real.

15. [x] Flag `--commit` en `Mix.Tasks.Motor.PropagarExtension`
    (`OptionParser.parse(args, strict: [commit: :string])`, mismo
    patrón que `--mensaje` en `motor.publicar`) -- sin el flag,
    comportamiento idéntico al de siempre (`resolver_imagen/3`, rama
    `nil`); con el flag, `MotorAlta.imagen_para_commit/1` en vez de
    consultar `<origen>`.
16. [x] `MotorAlta.imagen_para_commit/1` + `tags_del_registro/0` --
    `gh api users/prettycore-13/packages/container/metadata_stack/versions
    --paginate --jq '.[].metadata.container.tags[]'` (comando exacto
    confirmado a mano contra el registro real ANTES de escribir el
    código, encontrando ahí mismo los dos hallazgos de arriba).
17. [x] `Mix.raise` claro si el hash no existe como tag -- nunca llega a
    `gh workflow run` con un tag inventado (confirmado real, ver tarea 19).
18. [x] Test (`motor_alta_actualizacion_test.exs`) -- cubre lo no
    dependiente de red (gh ausente del PATH, mismo criterio que el
    resto del archivo); el caso "hash válido/inválido contra el
    registro real" se cubre con verificación real (tarea 19), sin mock
    de `gh api` (mismo criterio ya establecido en este proyecto).
19. [x] **Verificación real completa, contra infraestructura real**:
    - Hash inventado (`--commit=hashquenoexiste123`) → rechazado antes
      de disparar nada.
    - Hash real y viejo (`08fb6260dc4521414377d960bc825e67ce35568f`,
      commit real de este repo) → `mix motor.propagar_extension Metadata
      unstable testing --commit=...` disparó `actualizar-sistema.yml`
      de verdad, run completado ✓ en 20s, `testing` terminó en ESA
      imagen puntual (confirmado por el run, no en la más reciente de
      `unstable`).
    - `testing` restaurado después a `:latest` (lo que tenía antes de
      la prueba) vía `mix motor.propagar_extension Metadata unstable
      testing` sin flag -- run ✓ confirmado, ambiente compartido no
      quedó en un estado de prueba.
    - `mix test`: 666/668 (2 fallas preexistentes sin relación).

## Grupo E — Permiso + pantalla `/sysadmin/propagacion`, solo lectura (R9, R9a, R9b) ✅

> Separado a propósito de Grupo F (acción de disparar desde la UI) —
> primero la visibilidad (lo de más valor inmediato y menor riesgo),
> después la acción.

> **Fork resuelto con el usuario antes de implementar**: `design.md`
> §5.1 no contemplaba que la pantalla (a diferencia del CLI) no tiene
> un `<ambiente>` explícito natural, y ya hay 2 ambientes registrados
> (`Metadata`, `crm`). Decisión: selector `<select>` en la pantalla,
> preseleccionado solo si hay exactamente 1 registrado. `design.md`
> §5/§5.1 corregidos (`linea_de_tiempo/2`, no `/1`).

> **Hallazgo real importante, encontrado durante la verificación**: otra
> sesión concurrente había usado el MISMO número de spec
> (`SPEC-SYS-1809202601`) para un tema completamente distinto
> ("despublicar catálogo huérfano"), ya commiteado y pusheado a
> `origin/main` -- incluso con el MISMO rename de Grupo A
> (`motor.promover`→`motor.propagar_extension`, commit `39389a3`, sin
> contenido propio, diff vacío). Como esta spec (Propagación) seguía sin
> commitear, se renumeró completa a **`SPEC-SYS-1809202603`** (carpeta +
> las 17 referencias reales en código/docs/tests de esta sesión --
> verificado con grep que las referencias del OTRO spec, ya commiteadas,
> no se tocaron). `mix compile` + `mix test` limpios después del
> renombrado (668/670, mismas 2 fallas preexistentes).

20. [x] Migración `20260918131209_seed_permiso_capacidad_sysadmin_propagacion.exs`
    (mismo patrón que `20260816022113_...ambientes.exs`) — verificado
    antes (mix run, en vivo) que ni el rol ni el permiso existían
    todavía (regla "no asumir" del skill `spec`).
21. [x] `lib/metadata_app/propagacion_context.ex` —
    `linea_de_tiempo/2` (ambiente, limite): `git log origin/main`
    parseado (`%x1f` como separador), emparejado con
    `Estado.consultar_todo/2` (Grupo B) y con `gh run list --json ...`
    (mismo patrón `meta_tepache.ex:211`).
22. [x] `lib/metadata_app_web/live/sysadmin/propagacion_live.ex` — mount
    con gate `{"sysadmin_propagacion", "leer"}`, entrada agregada al
    `@menu` compartido de las 17 pantallas de Sysadmin (script
    PowerShell, uniforme), ruta en `router.ex`, opción agregada al grupo
    "plataforma" del menú administrativo (`MenuLayout`, R13a de
    `SPEC-SYS-0909202601`).
23. [x] Template: lista de commits con ícono de estado (✓/✗/○ según el
    run más reciente que aplica), mensaje, hash corto, autor + actor del
    run (R9b, campos separados), cuándo; chips de canal/sistema
    superpuestos. Botón "Actualizar" manual, sin polling — carga async
    (`start_async`) para no bloquear el render inicial mientras
    git+SSH+gh responden.
24. [x] Test `propagacion_live_test.exs` — gate RBAC (sin permiso no
    entra) + pantalla sin ambientes registrados. Sin mock de
    `PropagacionContext` (usa git/gh/SSH reales, mismo criterio ya
    establecido en este proyecto para todo lo que depende de esos 3) —
    los tests NO crean ningún `Ambiente` a propósito, así nunca disparan
    la carga async real dentro de la suite.
25. [x] Verificación real: `PropagacionContext.linea_de_tiempo/2` corrido
    a mano contra el ambiente "Metadata" real -- 5 commits, ~6s,
    hashes/autores/mensajes coinciden con `git log` a mano. Posiciones
    vacías en los 5 commits más recientes -- correcto: los ambientes
    reales corren `:latest` (no un tag por commit) salvo cuando se
    propaga explícito con `--commit=` (Grupo D), así que no hay match
    de hash hoy -- no es un bug, es el estado real de estos ambientes.

## Grupo F — Disparar propagación y rollback de código desde la pantalla (R9, R10) ✅

> **Fork resuelto con el usuario antes de implementar**: ¿la regla
> "nunca saltar Testing" del CLI (`@pares_validos`) también aplica acá,
> donde no hay un "origen" explícito, solo un commit puntual + destino
> elegidos? Confirmado que sí, reinterpretada como regla de predecesor
> por posición actual (`design.md` §5.2 actualizado): `testing` solo
> ofrecible si `unstable` ya está en `commit.posiciones`; `stable` solo
> si `testing` ya está ahí; un cliente solo si `stable` ya está ahí.

26. [x] Click en "Propagar..." de un commit → expande un picker inline
    (`commit_expandido`, toggle) con los destinos OFRECIBLES para ese
    commit (`PropagacionContext.destinos_ofrecibles/2`) — nunca todos
    los canales/clientes libremente. Dispara `MotorAlta.imagen_para_commit/1`
    + `MotorAlta.disparar_actualizacion/4` (mismo camino que Grupo D,
    incluida la guarda de idempotencia gratis).
27. [x] Botón de rollback (↺) en cada chip → `PropagacionContext.commit_anterior/2`
    resuelve el commit anterior en la lista ya cargada; el botón solo
    aparece si ese commit anterior cumple la misma regla de predecesor
    para ESE destino (consistencia con la tarea 26) — mismo `disparar/3`
    interno, cero camino de despliegue nuevo.
28. [x] `destino_ofrecible?/2`, `destinos_ofrecibles/2` y
    `commit_anterior/2` se movieron a `PropagacionContext` (lógica de
    dominio pura, no de vista) para poder testearlas sin red — 8 tests
    nuevos en `propagacion_context_test.exs` + 1 en `propagacion_live_test.exs`
    (`toggle_picker` no crashea). El disparo real (`imagen_para_commit`/
    `disparar_actualizacion`) sigue sin mock, mismo criterio ya
    establecido en este proyecto — se cubre con verificación real
    (tarea 29), no acá.
29. [x] Verificación real (confirmado con el usuario: `testing` de
    nuevo, mismo criterio que Grupo D) — un test temporal (armado y
    borrado en el momento, nunca quedó en la suite) recreó el ambiente
    real "Metadata" dentro de la transacción de test, navegó
    `/sysadmin/propagacion`, eligió el ambiente, esperó la carga async
    real (`render_async/2`, 30s) y abrió el picker de un commit real --
    **confirmado en vivo que el picker NO ofrece ningún destino hoy**,
    correctamente: los 4 ambientes reales corren `:latest` (no un tag
    por commit, ver Grupo E tarea 25), así que ningún commit satisface
    la regla de predecesor todavía -- la guarda funciona exactamente
    como debe. El mecanismo de disparo en sí (mismas funciones de
    `MotorAlta`) ya se había verificado real y con éxito en Grupo D
    (tarea 19) -- no se repitió un click de disparo real acá para no
    escalar más acciones sobre infraestructura compartida sin necesidad
    (la pantalla no agrega lógica de despliegue propia, solo conecta
    botones a lo ya probado). `mix test`: 676-679/679 según la corrida
    (algo de flakiness preexistente del entorno bajo carga con llamadas
    reales a git/SSH -- las fallas nombradas son siempre las mismas 2
    de siempre, ninguna nueva atribuible a este grupo).

## Grupo G — Detector de seguridad de migraciones (R10a) ✅

30. [x] `lib/metadata_app/propagacion_context/seguridad_migracion.ex` —
    `clasificar/1`: `Code.string_to_quoted!/1` + `Macro.prewalk/2` sobre
    el `def change` (`design.md` §6.2, pasos 1-3) — reconoce `create
    table`, `add` (dentro de `alter table`), `create index`/`unique_index`,
    y marca `remove`/`drop table`/`modify`/`execute` como manual
    siempre; cualquier construcción no reconocida → manual por default;
    una migración con `up`/`down` explícitos (sin `change`) → manual
    por default también (caso no cubierto explícitamente en `design.md`,
    mismo principio "ambigüedad → manual" aplicado).
31. [x] 15 tests (`seguridad_migracion_test.exs`), **sin tocar ninguna
    base** para `clasificar/1` (puro AST) — tabla nueva + índice
    (fixture real `20260804203016_crear_meta_schema_notificacion.exs`),
    columna nueva ×2 + índice único (fixture real
    `20260721210000_agregar_trn_a_meta_schema_header.exs`), `remove`/
    `drop table`/`modify`/`execute` → manual con motivo específico,
    construcción no reconocida → manual por default, mezcla de
    operaciones (una manual entre varias) → TODA la migración manual,
    `up`/`down` sin `change` → manual. **Bug real encontrado y
    corregido en el camino**: `resolver/1` asumía que todo lo
    no-manual era `{:candidata, _}`, pero `create index`/`unique_index`
    devuelve `{:automatico, _}` directo (nunca necesita verificación en
    vivo) — el primer test con un `create index` real crasheaba con
    `FunctionClauseError`; corregido para aceptar ambos tags.
32. [x] `verificar_vacio?/2` y `verificar_columna_sin_uso?/4` —
    consultan `MetadataApp.Repo` directo (no SSH/`kubectl exec` como
    decía `design.md` originalmente: en un release YA desplegado,
    `Repo` apunta al Postgres del destino real sin necesidad de SSH
    aparte, mismo mecanismo que `/app/bin/setup` — SSH solo hacía falta
    para lo que corre DESDE la laptop de dev, no para lo que corre
    DENTRO del release ya desplegado en destino). Tests con Postgres de
    test real (`MetadataApp.DataCase`, tabla temporal real) — tabla
    vacía/con filas, columna toda NULL/con default/con dato real.
33. [x] Verificación real (no destructiva): `clasificar/1` corrido a
    mano sobre 4 migraciones reales elegidas del historial —
    `renombrar_mostrar_en_grilla...` (up/down con SQL crudo) → manual;
    `eliminar_pty_..._clientesdet` (`drop table`) → manual con motivo
    literal; `agregar_empresa_default_a_usuario` (columna FK nullable)
    → automática candidata; `crear_meta_schema_credencial` (tabla +
    índice nuevos) → automática candidata. Las 4 coinciden exactamente
    con lo que diría un humano mirándolas. `mix test`: 692/694 (2
    fallas preexistentes sin relación).

## Grupo H — Rollback de base de datos (R10b) + integración final

34. [ ] `PropagacionContext` — dado un rollback de código (Grupo F),
    identificar las migraciones entre el commit actual y el destino
    (`git log --name-only`, filtrado a `priv/repo/migrations/`),
    clasificar cada una (Grupo G), decidir automático vs. manual para
    el conjunto completo (una sola manual → todo manual).
35. [ ] Camino automático: aplicar rollback de código primero
    (confirmado, `design.md` §6.3), recién después correr los `down`
    de Ecto contra el destino.
36. [ ] Camino manual: aplicar rollback de código igual, mostrar en la
    UI la migración bloqueante + operación exacta + conteo de filas si
    aplica + el aviso de "la base es responsabilidad manual".
37. [ ] Test de integración (`Propagacion Live` o context, mockeando
    `SeguridadMigracion`) — cubre ambos caminos, confirma que el
    camino manual NUNCA ejecuta un `down` sobre una migración marcada
    manual, sin excepción.
38. [ ] Verificación real de punta a punta, EN UN AMBIENTE DE PRUEBA
    (nunca un cliente real ni `stable` directo la primera vez): alta
    de una migración simple de prueba → propagar → confirmar en pantalla
    → rollback → confirmar que la tabla/columna de prueba desapareció
    de la base Y el código volvió a la imagen anterior.
39. [ ] `mix test` completo del proyecto — 0 failures nuevos respecto a
    la corrida base antes de este incremento.
40. [ ] Actualizar `docs/roadmap.md` si queda algo pendiente detectado
    durante la implementación (mismo criterio que incrementos previos
    de esta sesión — el spec queda vivo, no una foto).

## Nota — orden sugerido de ejecución

A: rename (bajo riesgo, base para todo lo demás) → B: visibilidad
(motor.estado_extension, valor inmediato, sin tocar nada destructivo)
→ C: idempotencia (protección antes de dar más poder de disparo) → D:
`--commit` (habilita E/F) → E: pantalla solo-lectura → F: disparo desde
UI → G: detector de migraciones (puede desarrollarse en paralelo a
E/F, es independiente) → H: integración final del rollback de DB, el
grupo más sensible, al final y con más verificación real.
