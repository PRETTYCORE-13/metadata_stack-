# SPEC-TEST-1509202601 — Seed Masterdata (developer mode)

**Documento:** Design · **Fase:** en definición, pendiente de revisión del usuario.

Diseño técnico de la herramienta descrita en `requirements.md`. Todo
lo de acá es propuesta para construir — nada de esto existe todavía
en el código.

## 0. Forma general

Dos mix tasks nuevos, namespace propio `seed.*` (para no chocar con
`motor.*`, que hoy significa "ciclo de vida de un SISTEMA completo" —
alta/despliegue/promoción — un concepto totalmente distinto a
"vaciar/poblar catálogos de un sistema ya alta"):

- `mix seed.vaciar` — Fase 1 (R1-R8).
- `mix seed.cargar` — Fase 2 (R9-R13).
- `mix seed.reset` — ambas encadenadas (R14): `vaciar` y, si salió
  bien, `cargar` sobre los mismos catálogos.

Un módulo de contexto nuevo, `MetadataApp.SeedMasterdata`, concentra
la lógica reusable entre los tres tasks (grafo de dependencias, orden
topológico, validación de nombres) — los tasks son capas finas de
CLI (parseo de args, `Mix.shell()`), igual que ya hace
`Mix.Tasks.Motor.Alta` delegando en `MetadataApp.MotorAlta`.

## 1. Grafo de dependencias (R2, R12)

**Decisión de diseño clave**: el grafo se calcula consultando
`information_schema` (FKs reales de Postgres), NO
`MetaSchemaContext.listar_dependientes/1`. Motivo, aprendido esta
misma sesión (borrado de `pty_dsd_pedidos` y de la carpeta
"Pedidos"): `listar_dependientes/1` solo ve un campo "referencia"
cuyo `catalogo` configurado es EXACTAMENTE el nombre del catálogo —
un campo "referencia a meta_schema_header" genérico (ej. `documento`
en `pty_folio_perfiles`, `tipo_transaccion` en
`pty_subtipos_transaccion`) queda invisible para esa función, pero
SÍ tiene una FK real de Postgres, y esa FK real es la que de verdad
rompe un `TRUNCATE`/`DELETE` sin importar qué diga la metadata.

`SeedMasterdata.grafo_dependencias/1` recibe la lista de catálogos
elegidos y arma un grafo dirigido A→B ("A tiene una FK real que
apunta a B, A no puede existir sin B") consultando
`information_schema.table_constraints` +
`key_column_usage`/`constraint_column_usage`, exactamente el mismo
tipo de consulta corrida a mano esta sesión — pero acotado a SOLO las
tablas del conjunto elegido (una FK hacia una tabla fuera del
conjunto no es un problema de esta herramienta, esa tabla no se va a
tocar).

`SeedMasterdata.orden_topologico/1` ordena ese grafo (Kahn) en dos
sentidos:

- **Orden de carga** (Fase 2): dependencias primero — B antes que A.
  Un catálogo maestro/referenciado siempre se puebla antes que quien
  lo referencia.
- **Orden de borrado** (Fase 1): el inverso exacto — A (quien
  referencia) antes que B (a quien referencian).

Un ciclo en el grafo (A referencia a B y B referencia a A) no debería
existir en un catálogo real, pero si aparece, `orden_topologico/1`
devuelve `{:error, :ciclo, [catálogos involucrados]}` — ninguno de
los dos tasks continúa, se lo reporta al developer para que lo
resuelva a mano (no hay una respuesta automática correcta a un ciclo
real de FKs).

## 2. Fase 1 — `mix seed.vaciar` (R1, R3-R8)

```
mix seed.vaciar --todos [--yes]
mix seed.vaciar pty_mat_fabricante pty_dsd_linea [--yes]
```

- **R5 (guardrail de nombre)**: `SeedMasterdata.validar_catalogo/1`
  rechaza cualquier nombre que no empiece con `pty_`/`demo100_` — se
  corta ahí, sin tocar nada, ni siquiera arma el grafo.
- **R6 (guardrail de ambiente)**: primera línea del task,
  `if Mix.env() != :dev, do: Mix.raise(...)`.
- **`--todos`**: `SeedMasterdata.listar_catalogos_desarrollo/0` — un
  `SELECT schema_context_name FROM meta_schema_header WHERE
  schema_context_name LIKE 'pty\_%' OR schema_context_name LIKE
  'demo100\_%'` (con `delete_guid IS NULL`), después el orden
  sugerido se calcula sobre ESA lista completa.
- **R3 (orden editable)**: nombrar los catálogos explícitos, EN EL
  ORDEN QUE SE QUIERA, en la línea de comando ES la forma de
  editar el orden sugerido — si el developer los escribe en un orden
  distinto al sugerido, se respeta el suyo tal cual (la herramienta
  no le impone nada, el orden automático es solo lo que se OFRECE
  con `--todos` o al pedirlo explícitamente, ver más abajo).
- **R7 (confirmación)**: sin `--yes`, imprime la lista final en el
  orden que va a usar y pide confirmación con `Mix.shell().yes?/1`
  antes de tocar la base. `--yes` la salta (uso no interactivo, ej.
  desde un script propio del developer).
- **R1/R8 (el borrado en sí)**: por cada catálogo, en orden,
  `TRUNCATE TABLE <tabla> RESTART IDENTITY` — sin `CASCADE`: si el
  orden calculado/elegido es correcto, nunca hace falta forzarlo, y
  si falla por una FK real es una señal de que el orden estaba mal
  (el error de Postgres ya es suficientemente claro, no hace falta
  ocultarlo con CASCADE). Nunca toca `meta_schema_header/detail/
  estados/transiciones/reglas_codigo` de ese catálogo — la estructura
  vive intacta.

## 3. Fase 2 — `mix seed.cargar` (R9-R13)

```
mix seed.cargar --todos
mix seed.cargar pty_mat_fabricante pty_dsd_linea
```

### 3.1 Formato del fixture (R9)

Un archivo Elixir por catálogo, en
`priv/repo/seed_masterdata/<catalogo>.exs`, que evalúa a una lista
plana de mapas — mismo espíritu que `priv/repo/seeds.exs`, nada de
sintaxis nueva que aprender:

```elixir
# priv/repo/seed_masterdata/pty_mat_fabricante.exs
[
  %{"pty_mat_fabricante_descripcion" => "GENERICA"},
  %{"pty_mat_fabricante_descripcion" => "IMPORTADOS SA"}
]
```

Un campo tipo "referencia" (R11) se escribe con el valor NATURAL del
registro destino, como texto plano — sin sintaxis especial:

```elixir
# priv/repo/seed_masterdata/pty_dsd_mat_lineas_sub.exs
[
  %{
    "pty_dsd_mat_lineas_sub_dsd_linea" => "ALIMENTOS",
    "pty_dsd_mat_lineas_sub_descripcion" => "ENLATADOS"
  }
]
```

`SeedMasterdata.resolver_referencia/3` sabe que
`pty_dsd_mat_lineas_sub_dsd_linea` es tipo "referencia" (lo lee de
`meta_schema_detail`, igual que el resto del motor) y busca, en el
catálogo destino (`pty_dsd_linea`) YA CARGADO en esta misma corrida,
la fila cuyo `campo_visualizacion` (la MISMA propiedad que el campo
"referencia" ya usa para decidir qué le muestra al usuario final, ver
`SPEC-SYS-1109202601` — sin `campo_visualizacion` configurado, cae al
mismo fallback `"#id"` que ya usa el resto del sistema, aunque ahí un
fixture con texto plano ya no podría resolverla — ver Grupo de
riesgo abajo) sea igual al texto dado ("ALIMENTOS"). Si no la
encuentra, es el error que dispara R13.

### 3.2 Camino real de alta (R10)

Por cada registro del fixture, en el orden de catálogos que dio
`orden_topologico/1` (dependencias primero) y en el orden del propio
archivo dentro de cada catálogo:

1. Resolver cualquier campo tipo "referencia" (3.1).
2. `MetaStateEngine.transicion_alta(catalogo)` para conocer la
   transición real de alta configurada.
3. `CatalogoGenerico.crear/2` (o el mismo camino que ya usa
   `CatalogoGenerico.crear_simple_o_rechazar/4` para catálogos con
   motor de estados) con los campos resueltos — el mismo código que
   ejecuta `POST /api/:tabla` hoy. TRN, folio (si aplica),
   `estado_id` de la transición de alta, y reglas PRE/POST corren
   exactamente igual que para un alta real.

### 3.3 Atomicidad (R13)

Toda la corrida de `mix seed.cargar` (todos los catálogos, todos los
registros de esa corrida) vive dentro de una única
`Repo.transaction/1`. Cualquier `{:error, motivo}` de
`CatalogoGenerico.crear/2` o de `resolver_referencia/3` dispara
`Repo.rollback/1` con el detalle del registro/catálogo que falló —
Ecto revierte la transacción completa, ningún registro de esa corrida
sobrevive. Riesgo técnico a confirmar en `tasks.md`: que ningún paso
interno de `crear/2`/`ejecutar_transicion/4` abra su PROPIA
`Repo.transaction/1` de forma incompatible con anidarse dentro de
otra (Ecto soporta transacciones anidadas vía SAVEPOINT de forma
transparente, pero hay que verificarlo en vivo, no asumirlo — mismo
criterio que `project_ecto_savepoint_retry` en memoria).

## 4. `mix seed.reset` (R14)

Encadena `seed.vaciar` (con `--yes` implícito, para no pedir
confirmación dos veces) y, solo si terminó bien, `seed.cargar` —
sobre el mismo conjunto/orden de catálogos. Si `seed.vaciar` falla
(ej. detecta un ciclo), `seed.cargar` ni se intenta.

## 5. Riesgos / puntos a validar en `tasks.md`

- **Sin `campo_visualizacion` configurado**: hoy el fallback del
  resto del sistema es mostrar `"#id"` — un fixture no puede escribir
  un id fijo (R11 lo prohíbe expresamente, los ids no son estables
  entre corridas). Un catálogo destino de una referencia, usado en un
  fixture, DEBE tener `campo_visualizacion` configurado — si no lo
  tiene, `resolver_referencia/3` debe fallar con un mensaje claro
  ("configurá campo_visualizacion en `<catalogo>` antes de poder
  referenciarlo desde un fixture"), no intentar adivinar.
- **Transacciones anidadas** (ver 3.3) — verificar contra Postgres
  real, no asumir.
- **Rendimiento**: `CatalogoGenerico.crear/2` corre reglas PRE/POST y
  motor de estados por cada fila — para el volumen chico que describe
  esta herramienta (datos de prueba, no miles de filas) no es un
  problema, pero si algún fixture crece mucho conviene medirlo antes
  de asumir que sigue siendo instantáneo.

## 6. Fuera de alcance

Igual que `requirements.md` §0.
