# SPEC-TEST-1509202601 — Seed Masterdata (developer mode)

**Documento:** Tasks · **Fase:** ✅ completa — Grupos A-E construidos y verificados contra Postgres real (2026-09-17).

Cada tarea es chica y verificable por separado. Seguir el orden: los
grupos posteriores dependen de que los anteriores compilen y pasen su
propia verificación.

## Grupo A — Contexto y grafo de dependencias ✅ (2026-09-17)

1. [x] Creado `MetadataApp.SeedMasterdata`
   (`lib/metadata_app/seed_masterdata.ex`) con `validar_catalogo/1`
   (rechaza cualquier nombre que no empiece con `pty_`/`demo100_`,
   R5) y `listar_catalogos_desarrollo/0` (todos los `pty_*`/
   `demo100_*` con header vivo y `schema_context_type == 1` — excluye
   carpetas/Consultas, sin tabla física propia, para `--todos`).
2. [x] `grafo_dependencias/1` — consulta `information_schema` (FKs
   reales entre las tablas del conjunto recibido, ver `design.md`
   §1). Verificado a mano contra Postgres real (32 catálogos de
   desarrollo actuales, cadena real `pty_dsd_mat_material` →
   `linea`/`fabricante`/`lineas_sub`/`marca`) — el grafo calculado
   coincide exactamente con una consulta manual a
   `information_schema`.
3. [x] `orden_topologico/2` — Kahn (implementado una sola vez sobre
   el sentido `:borrado`, `:carga` es su inverso) + `{:error, :ciclo,
   [...]}` si el grafo no es acíclico, reportando solo los nodos
   realmente involucrados en el ciclo. Bug real encontrado y
   corregido durante la implementación (no en el `design.md`
   original): la primera versión tenía las ramas `:carga`/`:borrado`
   invertidas — detectado con un trace a mano de A→B antes de
   escribir el test, no después.
4. [x] Tests ExUnit (`test/metadata_app/seed_masterdata_test.exs`, 8
   tests) — `validar_catalogo/1`, sin dependencias, cadena simple
   A→B→C, dependencia compartida (2 catálogos referencian al mismo),
   ciclo de 2 y de 3 nodos excluyendo nodos independientes. `mix
   test`: 607 tests, 0 failures (suite completa, sin regresiones).

## Grupo B — `mix seed.vaciar` ✅ (2026-09-17)

5. [x] `Mix.Tasks.Seed.Vaciar` (`lib/mix/tasks/seed.vaciar.ex`) —
   parseo de args: lista de nombres, `--todos`, `--yes`.
6. [x] Guardrails primero, antes de tocar cualquier dato: `Mix.raise`
   si `Mix.env() != :dev` (R6); `Mix.raise` si algún nombre no pasa
   `validar_catalogo/1` (R5) — se corta TODO el comando, reportando
   TODOS los nombres inválidos juntos, no solo el primero. Se agregó
   además (no estaba en `design.md`, encontrado natural durante la
   implementación) `validar_existencia/1` — un typo en un nombre con
   prefijo válido pero que no es tabla real corta el comando con un
   mensaje claro, en vez de fallar a mitad de la lista con "relation
   does not exist" después de haber vaciado los anteriores.
7. [x] Orden: con nombres explícitos, se respeta tal cual como se
   escribieron (R3 — la herramienta nunca reordena lo que el
   developer ya eligió); con `--todos`, `grafo_dependencias/1` +
   `orden_topologico/2 :borrado`. Se imprime la lista final y se pide
   confirmación (`Mix.shell().yes?/1`) salvo `--yes` (R7).
8. [x] `DELETE FROM <tabla>` + reinicio manual de la secuencia de
   `id` por catálogo, en el orden ya definido (R1, R8). **Corregido**
   (ver Grupo D, tarea 16.5): la versión original usaba `TRUNCATE`,
   cambiada a `DELETE` al encontrar el bug real de Postgres descrito
   ahí — este ítem se marca `[x]` reflejando el estado FINAL, no la
   primera versión.
9. [x] Verificación real en dev:
   - `pty_mat_fabricante` tenía 2 filas reales (de una sesión
     anterior) — `mix seed.vaciar pty_mat_fabricante --yes` las dejó
     en 0, y `meta_schema_estados`/`transiciones`/`detail` de ese
     catálogo confirmados intactos por `psql` (2 estados, 4
     transiciones, 2 campos, sin cambios).
   - Guardrails probados en vivo: nombre no-pty (`meta_schema_usuario`)
     rechazado; typo con prefijo válido (`pty_mat_fabricantex`)
     rechazado por `validar_existencia/1`; sin args ni `--todos`,
     mensaje de uso.
   - `--todos` con confirmación cancelada (`echo n |`): imprimió el
     orden completo (32 catálogos, orden verificado a mano contra la
     cadena real `vigencias_frec → clientes_ope → clientes →
     {grupos/cluster/cuentas_clave/fac_rfc/canales}`) y NO tocó nada
     — confirmado por `psql` que `pty_dsd_linea` siguió con sus 2
     filas.
   - Esta herramienta nunca corre fuera de `:dev` (R6) — no aplica
     replicar la verificación contra la base de test.
   - `mix test`: 607 tests, 0 failures (sin regresiones).

## Grupo C — Fixtures y resolución de referencias ✅ (2026-09-17)

10. [x] `priv/repo/seed_masterdata/` con 3 fixtures piloto:
    `pty_mat_fabricante.exs` (simple), `pty_dsd_linea.exs` (repite el
    escenario "ALIMENTOS"/"OTROS" que ya estaba cargado a mano en
    dev) y `pty_dsd_mat_lineas_sub.exs` (con una referencia real a
    `pty_dsd_linea` por texto natural) — formato de `design.md` §3.1.
11. [x] `resolver_referencia/2` (`design.md` corregido de `/3` a `/2`,
    la firma real quedó en 2 args) — reusa
    `CatalogoGenerico.opciones_referencia/1` (hallazgo del cierre de
    Grupo A) en vez de leer `campo_visualizacion` a mano. Si NINGUNA
    etiqueta del catálogo destino escapa del patrón `"#<id>"` (ni
    `campo_visualizacion` ni `campos_acompanamiento` configurados),
    falla proactivo — no deja pasar un `"no encontrado"` genérico.
12. [x] Tests ExUnit
    (`test/metadata_app/seed_masterdata_referencia_test.exs`, 4
    tests, contra `meta_schema_empresa` como catálogo destino — de
    sistema, sin depender de ningún `pty_*` de dev): encuentra por
    `campo_visualizacion`, encuentra por `campos_acompanamiento`
    (fallback), no encontrado, y sin ninguna configuración (error
    proactivo). Verificado además a mano contra Postgres real de dev
    con los 4 mismos casos, incluido uno construido a propósito
    (ningún catálogo real hoy carece de las dos configuraciones a la
    vez). `mix test`: 611 tests, 0 failures.

## Grupo D — `mix seed.cargar` (camino real + atomicidad) ✅ (2026-09-17)

13. [x] `Mix.Tasks.Seed.Cargar` (`lib/mix/tasks/seed.cargar.ex`) —
    mismos guardrails que `seed.vaciar` (R5, R6), mismo parseo de
    args (`--todos`/lista explícita). `--todos` carga SOLO los
    catálogos que tienen fixture (no hace falta uno por cada catálogo
    de desarrollo existente); con nombres explícitos, TODOS tienen
    que tener fixture o corta el comando completo.
14. [x] Por catálogo (orden `:carga` — dependencias primero) y por
    registro (orden del archivo): resolver referencias
    (`resolver_attrs/2`), crear vía `CatalogoGenerico.crear(schema_mod,
    :sistema, attrs)` (R9/R10). **Corregido vs. `design.md` original**:
    NO se llama a `MetaStateEngine.transicion_alta/1` a mano —
    `crear/4` ya la resuelve sola internamente (hallazgo al leer
    `catalogo_generico.ex:396` antes de escribir código de más).
15. [x] `SeedMasterdata.cargar/1` — arma la lista plana de
    `{catalogo, índice, registro}` ANTES de abrir la transacción (un
    fixture con error de sintaxis se reporta sin tocar la base), y
    corre TODO dentro de una sola `Repo.transaction/1`; el primer
    `{:error, _}` dispara `Repo.rollback/1` con `"catalogo[índice]:
    motivo"` (R13) — `formatear_motivo/1` traduce un
    `%Ecto.Changeset{}` a texto legible (campo + mensaje), no
    `inspect/1` crudo.
16. [x] **Bug real encontrado en vivo, no previsto en `design.md`**:
    al probar el borrado ordenado de los 3 catálogos piloto para
    dejar todo limpio antes de este grupo, `TRUNCATE` de
    `pty_dsd_mat_lineas_sub` reventó con "cannot truncate a table
    referenced in a foreign key constraint" — Postgres rechaza
    `TRUNCATE` si CUALQUIER tabla de la base entera (esté o no en la
    lista) referencia la tabla, sin importar el orden calculado.
    Corregido en Grupo B (tarea 8, retroactivo): `seed.vaciar` pasó
    de `TRUNCATE` a `DELETE` + reinicio manual de secuencia — `DELETE`
    solo falla ante una FILA real en conflicto, ahí sí el orden
    calculado importa y alcanza. Ver `design.md` §2/§5 para el
    detalle completo.
16.5. [x] **Verificación crítica de atomicidad, contra Postgres REAL
    de dev** (no `mix test` — la memoria `project_ecto_savepoint_retry`
    advierte que el sandbox de test enmascara esto): fixture temporal
    de 3 registros contra `pty_mat_fabricante` (vacío), 3° registro
    deliberadamente duplicado del 1° (dispara `unique_constraint`
    real). Resultado: registros 1 y 2 se insertaron sin error
    (`INSERT` + `meta_schema_transicion_eventos` +
    `meta_schema_transaction_registry` + `meta_schema_auditoria`, con
    TRN real), el 3° falló, `seed.cargar` reportó "Corrida deshecha
    por completo" — `SELECT count(*) FROM pty_mat_fabricante` dio
    **0**. La anidación de transacciones (inevitable, ver `design.md`
    §3.3) revierte TODO, exactamente como predijo el diseño. Fixture
    de prueba restaurado a su contenido real después de verificar.
17. [x] Verificación real en dev (camino feliz): `mix seed.cargar
    pty_mat_fabricante` con las 2 filas reales del fixture piloto —
    `estado_id` = Activo (68) confirmado por `psql`, TRN real
    asignado (`5GXW-260917-...`), `meta_schema_transicion_eventos`/
    `meta_schema_transaction_registry`/`meta_schema_auditoria`
    poblados igual que un alta real. Acotado a este único catálogo a
    propósito — `pty_dsd_linea`/`pty_dsd_mat_lineas_sub` (los otros 2
    del piloto) tienen datos reales de `pty_dsd_mat_material` (de una
    sesión anterior) dependiendo de ellos, fuera de este grupo tocar
    esos sin que se pida explícitamente. La resolución de referencias
    ya quedó verificada a fondo en Grupo C. `mix test`: 611 tests, 0
    failures (sin regresiones).

## Grupo E — `mix seed.reset` y cierre ✅ (2026-09-17)

18. [x] `Mix.Tasks.Seed.Reset` (`lib/mix/tasks/seed.reset.ex`) —
    reenvía los MISMOS `args` a `Mix.Task.run("seed.vaciar", args)` y,
    si no reventó, a `Mix.Task.run("seed.cargar", args)` (R14).
    **Corregido vs. `design.md` original** ("`--yes` implícito"): eso
    hubiera hecho que `seed.reset` nunca pidiera confirmación, ni una
    vez — reenviar los mismos args alcanza para "no pedir dos veces"
    sin inventar un default más peligroso que el resto de la
    herramienta (sin `--yes` pide UNA vez, la de vaciar — cargar nunca
    pregunta nada).
19. [x] Mensajes de error revisados — ya quedaron accionables al
    escribirlos (cada uno probado en vivo durante Grupos B-D):
    prefijo inválido, tabla inexistente (typo), ciclo de dependencias,
    sin fixture, `campo_visualizacion`/`campos_acompanamiento`
    faltante, ambiente incorrecto, corrida atómica deshecha con
    catálogo+índice+motivo exactos.
20. [x] `mix compile --force` limpio (sin warnings nuevos, ninguno
    sobre `seed.*`). `mix test`: 611 tests, 0 failures.
21. [x] Entrada agregada a `docs/specs/README.md`.

### Verificación real en dev — cadena completa

`mix seed.reset pty_mat_fabricante --yes`: vació el catálogo (2 filas
→ 0), encadenó `seed.cargar` sin fricción (mismo proceso, doble
`Ecto.Migrator.with_repo/3` sin problema), recreó las 2 filas del
fixture con ids reiniciados en 1/2 (confirma que `DELETE` + reinicio
de secuencia de la Fase 1 funciona) y TRN real nuevo — confirmado por
`psql`. `mix seed.reset meta_schema_usuario --yes` (nombre inválido):
cortó con el mismo mensaje de `seed.vaciar`, "Se van a cargar" NUNCA
se imprimió — confirma R14 (si vaciar falla, cargar ni se intenta).

## Nota

A diferencia de las specs retroactivas del módulo BC Motor (donde
`tasks.md` era en su mayoría verificación de código ya funcionando),
acá cada tarea es construcción real — no marcar `[x]` hasta que el
código exista, compile, y la verificación descrita se haya corrido
de verdad contra Postgres.
