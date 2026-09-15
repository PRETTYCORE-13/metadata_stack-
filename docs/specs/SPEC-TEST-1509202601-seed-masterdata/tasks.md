# SPEC-TEST-1509202601 — Seed Masterdata (developer mode)

**Documento:** Tasks · **Fase:** pendiente de construir — nada de esto existe en el código todavía.

Cada tarea es chica y verificable por separado. Seguir el orden: los
grupos posteriores dependen de que los anteriores compilen y pasen su
propia verificación.

## Grupo A — Contexto y grafo de dependencias

1. [ ] Crear `MetadataApp.SeedMasterdata` con
   `validar_catalogo/1` (rechaza cualquier nombre que no empiece con
   `pty_`/`demo100_`, R5) y `listar_catalogos_desarrollo/0` (todos
   los `pty_*`/`demo100_*` con header vivo, para `--todos`).
2. [ ] `grafo_dependencias/1` — consulta `information_schema` (FKs
   reales entre las tablas del conjunto recibido, ver `design.md`
   §1). Probar a mano contra un par de catálogos con FK real conocida
   de esta sesión (ej. si se recrean `pty_folio_perfiles`/
   `pty_subtipos_transaccion`) para confirmar que detecta la relación
   que `MetaSchemaContext.listar_dependientes/1` NO detecta.
3. [ ] `orden_topologico/1` — Kahn en ambos sentidos (carga:
   dependencias primero; borrado: inverso) + `{:error, :ciclo, [...]}`
   si el grafo no es acíclico.
4. [ ] Tests ExUnit de `grafo_dependencias/1`/`orden_topologico/1`
   contra catálogos de prueba armados en el propio test (no depender
   de que existan catálogos reales en la base de test) — casos: sin
   dependencias, cadena simple A→B→C, y un ciclo forzado.

## Grupo B — `mix seed.vaciar`

5. [ ] `Mix.Tasks.Seed.Vaciar` — parseo de args: lista de nombres,
   `--todos`, `--yes`.
6. [ ] Guardrails primero, antes de tocar cualquier dato: `Mix.raise`
   si `Mix.env() != :dev` (R6); `Mix.raise` si algún nombre no pasa
   `validar_catalogo/1` (R5) — se corta TODO el comando, no solo el
   catálogo inválido.
7. [ ] Calcular orden (grafo + `orden_topologico/1` de borrado, salvo
   que el developer haya pasado una lista explícita — ahí se respeta
   tal cual, R3), imprimir la lista final, pedir confirmación
   (`Mix.shell().yes?/1`) salvo `--yes` (R7).
8. [ ] Ejecutar `TRUNCATE TABLE <tabla> RESTART IDENTITY` por
   catálogo, en el orden ya definido (R1, R8) — sin `CASCADE`.
9. [ ] Verificación real en dev: crear 2-3 filas de prueba en un
   catálogo `pty_*` ya existente, correr `mix seed.vaciar
   <catalogo>`, confirmar por `psql` que quedó en 0 filas Y que
   `meta_schema_header/detail/estados/transiciones` de ese catálogo
   siguen intactos (R1).

## Grupo C — Fixtures y resolución de referencias

10. [ ] Definir `priv/repo/seed_masterdata/` y escribir 2-3 archivos
    de fixture reales como piloto (ej. `pty_mat_fabricante.exs`,
    `pty_dsd_linea.exs`) — formato de `design.md` §3.1.
11. [ ] `resolver_referencia/3` — dado un campo tipo "referencia" y
    un valor de texto, busca en el catálogo destino por
    `campo_visualizacion`. Si el catálogo destino no tiene
    `campo_visualizacion` configurado, error claro (no intentar
    `"#id"`, ver `design.md` §5) — verificar este caso específico con
    un catálogo real sin esa propiedad configurada.
12. [ ] Test ExUnit de `resolver_referencia/3`: encuentra por valor
    natural, falla claro si no existe, falla claro si falta
    `campo_visualizacion`.

## Grupo D — `mix seed.cargar` (camino real + atomicidad)

13. [ ] `Mix.Tasks.Seed.Cargar` — mismos guardrails que `seed.vaciar`
    (R5, R6), mismo parseo de args (`--todos`/lista explícita).
14. [ ] Por catálogo (orden de carga: dependencias primero) y por
    registro (orden del archivo): resolver referencias, obtener la
    transición de alta real (`MetaStateEngine.transicion_alta/1`),
    crear vía `CatalogoGenerico.crear/2` (mismo camino que
    `POST /api/:tabla`, R9/R10).
15. [ ] Envolver TODA la corrida en una sola `Repo.transaction/1`;
    cualquier error dispara `Repo.rollback/1` con el detalle exacto
    (catálogo + índice del registro + motivo, R13).
16. [ ] **Verificar en vivo, no asumir** (riesgo señalado en
    `design.md` §3.3/§5): confirmar que `CatalogoGenerico.crear/2` /
    `MetaStateEngine.ejecutar_transicion/4` no abren una
    `Repo.transaction/1` propia incompatible con anidarse — probar
    contra Postgres real un fixture de 2+ registros donde el ÚLTIMO
    falla a propósito, y confirmar por `psql` que NINGUNO de los
    anteriores quedó persistido.
17. [ ] Verificación real en dev: correr `mix seed.cargar` sobre el
    fixture piloto del Grupo C (catálogos ya vaciados por el Grupo
    B), confirmar por `psql` que las filas creadas tienen TRN real,
    `estado_id` correcto, y folio asignado si el catálogo lo
    requiere.

## Grupo E — `mix seed.reset` y cierre

18. [ ] `Mix.Tasks.Seed.Reset` — encadena `seed.vaciar` (con `--yes`
    implícito) y, solo si salió bien, `seed.cargar`, mismo conjunto/
    orden de catálogos (R14).
19. [ ] Revisar que todos los mensajes de error sean accionables:
    ciclo de dependencias, `campo_visualizacion` faltante, prefijo de
    catálogo inválido, ambiente incorrecto — cada uno debe decirle al
    developer exactamente qué hacer, no solo qué falló.
20. [ ] `mix compile --force` limpio (dev y test, sin warnings
    nuevos). `mix test` completo sin regresiones.
21. [ ] Agregar la entrada de esta spec a `docs/specs/README.md`.

## Nota

A diferencia de las specs retroactivas del módulo BC Motor (donde
`tasks.md` era en su mayoría verificación de código ya funcionando),
acá cada tarea es construcción real — no marcar `[x]` hasta que el
código exista, compile, y la verificación descrita se haya corrido
de verdad contra Postgres.
