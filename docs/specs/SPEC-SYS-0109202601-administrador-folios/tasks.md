# SPEC-SYS-0109202601 — Administrador de Folios de Transacciones

**Documento:** Tasks · **Fase:** ✅ aprobada (2026-09-01), ejecución en
curso. Cada tarea es chica y verificable por sí sola (compila, corre,
o un test pasa) — se ejecutan en orden, una por vez. Marcar `[x]` a
medida que se completan (tarea 23).

> Reordenado (2026-09-01): `folio_perfiles` se crea como BC real (§6)
> ANTES del motor de asignación — el motor necesita que el módulo
> generado ya exista para poder referenciarlo. Mismo error de secuencia
> que ya pisé una vez con `pty_ndt_configuracion`; corregido antes de
> ejecutar, no a mitad de camino esta vez.

## Grupo A — Base: columna en Header + macro del generador ✅

1. [x] **Migración**: `requiere_folio` (boolean, default `false`) en
   `meta_schema_header` — §4.
2. [x] **`Header` (schema + changeset)**: castear `requiere_folio` +
   validar que solo pueda ser `true` si `schema_es_transaccional:
   true` — §4 nota de alcance.
3. [x] **`MetaCatalogoGenerico`**: opción `folio: true` en `__using__/1` →
   agrega `field :folio_serie, :string` + `field :folio_numero,
   :integer`, fuera de `@campos` — §3.3/§4.
4. [x] **`CatalogoGenerador`**: emitir las dos columnas en la migración de
   creación (catálogo nuevo) Y en el retrofit (`ALTER TABLE`, catálogo
   existente que activa `requiere_folio` después) — §4.
5. [x] **Verificar**: `mix compile` limpio, un catálogo de prueba con
   `folio: true` expone `folio_serie`/`folio_numero` en
   `__schema__(:fields)`.

## Grupo B — `folio_perfiles` como BC real (§6) ✅

6. [x] **Catálogo `pty_folio_perfiles`**: creado vía el motor de
   catálogos (`MetaSchemaContext.crear_header_con_detalles/1` +
   `CatalogoGenerador.generar/1`) — campos de negocio: `documento`
   (`referencia` → `meta_schema_header`), `subtipo_transaccion`
   (`integer`, opcional), `sucursal` (`referencia` →
   `meta_schema_branch`, opcional), `serie` (`string`, longitud 4),
   `numero_inicial` (`integer`, opcional, default 1). Sin autómata.
   Gap encontrado y resuelto: `validar_campos_acompanamiento/1` solo
   conoce catálogos BPB reales (consulta `meta_schema_detail`), no
   catálogos de sistema como `meta_schema_header`/`meta_schema_branch`
   — se dejó sin `campos_acompanamiento` en esos dos campos (cae al
   fallback `"#id"`), arreglar ese validador queda fuera de alcance.
7. [x] **`numero_actual`**: columna física agregada a mano
   (`ALTER TABLE`) DESPUÉS de que el catálogo ya existía — confirmado
   NO forma parte del módulo Ecto auto-generado (ese lo usa la Ficha/
   CRUD genérico, tiene que quedar ciego a esta columna). El motor
   (Grupo D) declara su PROPIO schema Ecto liviano sobre la misma
   tabla física, con `numero_actual` incluido — dos schemas, misma
   tabla, cada uno con el subconjunto de columnas que le toca.
8. [x] **Publicado**: `/sistema/transacciones/folio-perfiles` (carpetas
   Sistema → Transacciones creadas).
9. [x] **Permisos**: leer/crear/editar sobre `pty_folio_perfiles`,
   rol nuevo **`pty-funcional-admin`** con los tres concedidos.
   "administrador" ya tenía acceso total por bypass, sin cambios ahí.
10. [x] **Verificado**: `pty_folio_perfiles.ex` compila con los 5
    campos de negocio esperados; `numero_actual` confirmado como
    columna física (`integer NOT NULL DEFAULT 0`) en dev y test.

## Grupo C — Tabla `folio_historial` (ledger interno, hecho a mano) ✅

No es un BC — es un ledger append-only sin Ficha/Get View, mismo rol
que `meta_schema_transaction_registry` ya tiene para TRN.

11. [x] **Migración + schema `FolioHistorial`**: tabla `folio_historial`
    tal cual §2.2 (FK a `pty_folio_perfiles`, sin `updated_at`).
12. [x] **Verificado**: `mix ecto.migrate` corrió limpio en dev y test.

## Grupo D — Motor de asignación (aislado, sin enganchar todavía) ✅

13. [x] **`MetadataApp.IdentificadoresTransaccionales`**: resolución de
    perfil — §3.1 (los tres exactos, fallback de Sucursal a global,
    sin fallback de Subtipo).
14. [x] **Misma función**: paso de asignación — §3.2, con un
    refinamiento encontrado acá (documentado en design.md): el
    incremento usa `GREATEST(numero_actual, numero_inicial - 1) + 1`
    en vez de un `+ 1` simple, porque `numero_actual` nunca se siembra
    con `numero_inicial` al crear el perfil. Reusa
    `TRN.asignar_si_transaccional/1` TAL CUAL para TRN — otro
    descubrimiento: no hizo falta "adaptarlo" (Ecto no abre una
    transacción real anidada), compone solo dentro de la transacción
    externa.
15. [x] **API pública `asignar/4`** — §5, firma exacta y los 3 casos.
16. [x] **8 tests del motor**, sin tocar `catalogo_generico.ex`
    todavía: folio consecutivo (respeta `numero_inicial`), Serie sin
    relleno de ceros (R1a), TRN+Folio en el mismo paso, fallback de
    Sucursal a global, Subtipo SIN fallback (con y sin match), sin
    perfil configurado, y **100 pedidos concurrentes → secuencia
    exacta 1..100, sin huecos ni duplicados** (R3).

## Grupo E — Enganche atómico (el cambio de mayor riesgo) ✅

17. [x] **`crear_simple/3` → `crear_simple/4`**: ahora recibe `header`
    (resuelto una sola vez por el caller) y llama
    `IdentificadoresTransaccionales.asignar/4` DENTRO del
    `Repo.transaction` existente, entre el `Repo.insert` y
    `Renglones.crear_todos/3` — §1.2.
18. [x] **`MetaStateEngine.ejecutar_nucleo_alta/4`**: header resuelto
    ahí mismo vía `transicion.meta_schema_header_id` (sin query extra
    por nombre); se sumó `Multi.run(:identificadores, ...)` al `Multi`
    existente, al final (después de `:renglones`) — §1.2. Nuevo match
    `{:error, :identificadores, razon, _}` agregado junto al de
    `:renglones`.
19. [x] **`catalogo_generico.ex` (`crear_con_attrs_preparados/5`)**:
    retirada la llamada suelta a
    `MetadataApp.TRN.asignar_si_transaccional/1` — el comentario viejo
    ("PrettyCore TRN corre DESPUÉS del insert") se reemplazó por uno
    que apunta a `IdentificadoresTransaccionales` y design.md §1.2.
20. [x] **Test de regresión** (nuevo archivo
    `identificadores_transaccionales_enganche_test.exs`): catálogo
    transaccional SIN folio recibe TRN igual que antes, probado por
    los DOS caminos reales (`crear_simple/4` y
    `MetaStateEngine.ejecutar_nucleo_alta/4` vía una transición "alta"
    configurada, mismo patrón que
    `alcance_de_datos_escritura_test.exs`). Forzar una colisión REAL
    de TRN (aleatorio+segundo) no es practicable sin tocar código de
    producción para inyectar el random — se dejó fuera; lo que se
    prueba es que el punto de enganche nuevo no rompió la asignación
    de TRN en sí, por ninguno de los dos caminos.
21. [x] **Test de atomicidad (R7)**, mismo archivo: `renglones_spec`
    apunta a un catálogo detalle inexistente → `Renglones.crear_todos/3`
    falla DESPUÉS de que el folio ya se generó (perfil bloqueado,
    `numero_actual` incrementado, `folio_historial` insertado) →
    verificado que la transacción entera revierte: cero filas nuevas
    en `folio_historial`, `numero_actual` sin incrementar, y el
    registro nunca queda en la tabla.

## Grupo F — Cierre ✅

22. [x] **Suite completa** (`mix test`): 461 tests, 2 failures — ambos
    preexistentes y sin relación con este cambio (`meta_tepache_test.exs`,
    tar de Windows sin soporte de rutas UNC; `ambientes_live_test.exs`,
    un campo `docker_servicio` que no está en el formulario actual). Sin
    failures nuevas.
23. [x] **Verificación end-to-end contra la DB de dev real** (sin
    herramienta de browser disponible en este entorno — se sustituyó
    por un script `mix run` envuelto en `Repo.transaction` +
    `Repo.rollback` intencional al final, contra la base de `dev`, NO
    `test`): crea un header transaccional con `requiere_folio: true`,
    un perfil (`PtyFolioPerfiles`, `numero_inicial: 500`) y un registro
    vía `CatalogoGenerico.crear/3` real — confirmado `trn`/`ulid`/
    `folio_serie`/`folio_numero` asignados juntos, respetando
    `numero_inicial`. Verificado por consulta directa a Postgres que el
    rollback no dejó ningún residuo (header/perfil/historial/registro
    en 0). Pendiente si se quiere: click-through real en el navegador
    (crear perfil desde `/sistema/transacciones/folio-perfiles`, dar de
    alta un catálogo con `requiere_folio` desde la UI) — no cubierto
    acá por falta de herramienta de browser.

## Grupo G — R8, Subtipo dado de baja (agregado 2026-09-01, a pedido explícito) ✅

Caso no contemplado en el diseño original, señalado por el usuario
después de cerrado el Grupo F: un Subtipo dado de baja no debe poder
foliar, sin importar el canal (R5) — ver requirements.md R8 y
design.md §2.

25. [x] **Catálogo `pty_subtipos_transaccion`**: BC real, `tipo_transaccion`
    (`referencia` → `meta_schema_header`, obligatorio) + `descripcion`
    (`string`). Autómata propio: Activo (inicial) → Baja, sin
    reactivación. Permisos leer/crear/editar concedidos a
    `pty-funcional-admin`. Creado en dev Y test (header/estados/
    transiciones/permisos son filas de aplicación, no vienen con la
    migración — mismo gotcha ya documentado para `pty_folio_perfiles`).
26. [x] **`IdentificadoresTransaccionales.asignar_folio/3`**:
    `verificar_subtipo_activo/2` corta ANTES de resolver perfil (sin
    lock, sin incremento) si el subtipo está en el estado destino de su
    transición "baja". `{:error, :subtipo_dado_de_baja}`.
27. [x] **2 tests nuevos** en `identificadores_transaccionales_test.exs`:
    subtipo activo folía normal; subtipo dado de baja bloquea Y confirma
    que el perfil configurado para ese subtipo ni se tocó
    (`numero_actual` sigue en 0).
28. [x] Suite completa: 463 tests, mismos 2 failures preexistentes de
    Grupo F, ninguno nuevo. `requirements.md` (R8) y `design.md` (§2)
    actualizados.
24. [x] Este documento, actualizado a medida que se completó cada
    grupo.

## Grupo H — Ajustes post-cierre (2026-09-02) ✅

29. [x] **Recuperación tras rename manual de campo**: el usuario
    renombró a mano (Field Designer) el campo "Subtipo" de
    `pty_folio_perfiles` — de `subtipo_transaccion` (integer suelto) a
    `pty_folio_perfiles_subtipos_transaccion` (`referencia` real →
    `pty_subtipos_transaccion`, con FK). Rompió el motor (columna
    física distinta a la que el schema interno esperaba) y dejó el
    campo `opcional: false` (bloqueaba perfiles "globales", sin
    subtipo). Arreglado: `FolioPerfil` (schema interno del motor) usa
    `source:` para mapear su campo Elixir `subtipo_transaccion` a la
    columna física real, sin tocar el resto del motor; campo vuelto a
    `opcional: true`; metadata de `test` sincronizada con `dev`
    (tenía la fila vieja, la migración de columna sí había corrido en
    las dos por el alias `mix test`, pero la metadata de aplicación
    no). Ver [design.md §2.1](design.md) y
    [folio_perfil.ex](../../../lib/metadata_app/identificadores_transaccionales/folio_perfil.ex).
30. [x] **Checkbox "Folio" en el wizard "Nuevo Completo"**
    ([bc_nuevo_completo_live.ex](../../../lib/metadata_app_web/live/sysadmin/bc_nuevo_completo_live.ex)):
    antes `requiere_folio` solo se podía prender por SQL/consola, sin
    ningún checkbox — agregado debajo del de "TRN", mismo mecanismo,
    validado (folio sin transaccional se rechaza con mensaje claro).
    Ver design.md §4 nota "UI para activarlo". Sigue sin existir un
    toggle para un catálogo YA creado (solo al nacer, vía este
    wizard).
31. [x] Verificado con `mix test` (suite completa, mismos 2 failures
    preexistentes) y con scripts de humo contra `dev` real (rollback,
    sin residuo) — casos válido e inválido de la nota de alcance de
    §4.
