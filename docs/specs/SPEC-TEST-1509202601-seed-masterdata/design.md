# SPEC-TEST-1509202601 — Seed Masterdata (developer mode)

**Documento:** Design · **Fase:** ✅ completa — Grupos A-E construidos y verificados (2026-09-17), varias correcciones reales encontradas en el camino, ver §1-§5.

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

`SeedMasterdata.orden_topologico/2` ordena ese grafo (Kahn) en dos
sentidos:

- **Orden de carga** (Fase 2): dependencias primero — B antes que A.
  Un catálogo maestro/referenciado siempre se puebla antes que quien
  lo referencia.
- **Orden de borrado** (Fase 1): el inverso exacto — A (quien
  referencia) antes que B (a quien referencian).

Un ciclo en el grafo (A referencia a B y B referencia a A) no debería
existir en un catálogo real, pero si aparece, `orden_topologico/2`
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
- **Guardrail extra, no previsto originalmente**: además de R5/R6,
  `seed.vaciar` valida que cada nombre exista como tabla real
  (`to_regclass`) antes de tocar cualquiera — un typo con prefijo
  válido (`pty_mat_fabricantex`) corta el comando con un mensaje
  claro, en vez de fallar a mitad de la lista con "relation does not
  exist" después de vaciar los anteriores.
- **R1/R8 (el borrado en sí)**: `DELETE FROM <tabla>` + reinicio
  manual de la secuencia de `id` (`pg_get_serial_sequence` +
  `ALTER SEQUENCE ... RESTART WITH 1`) por catálogo, en el orden ya
  definido. **NO `TRUNCATE`** — bug real encontrado en vivo
  (2026-09-17, ver el comentario completo en `vaciar_catalogo/1`):
  Postgres rechaza `TRUNCATE` de una tabla si CUALQUIER OTRA tabla de
  la base entera (esté o no en la lista que se está vaciando) tiene
  una FK real apuntándole, sin importar el orden calculado —
  distinto de `DELETE`, que solo falla si hay una FILA real en
  conflicto. El diseño original asumía que el orden topológico
  alcanzaba para evitar el error con `TRUNCATE`; no es así, el orden
  solo importa para `DELETE`. Nunca toca `meta_schema_header/detail/
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

`SeedMasterdata.resolver_referencia/2` sabe que
`pty_dsd_mat_lineas_sub_dsd_linea` es tipo "referencia" (lo lee de
`meta_schema_detail`, igual que el resto del motor) y reusa
`CatalogoGenerico.opciones_referencia/1` — la MISMA función que arma
el picker real de un campo "referencia" (`catalogo_generico.ex:1076`)
— pasándole las `props` de ese campo. Devuelve `[{id, etiqueta}, ...]`
del catálogo destino (`pty_dsd_linea`), ya con el texto resuelto
según `campo_visualizacion` (real, con sus 4 modos posibles —
descripcion/codigo_descripcion/plantilla/calculado, no un simple
nombre de campo como se asumió en una versión anterior de este
diseño, corregido 2026-09-17 al llegar a Grupo C) o, si no está
configurado, `campos_acompanamiento`, o como último recurso `"#id"`
(`etiqueta_para_referencia/2`, pública, línea 1156). `resolver_referencia/2`
busca la entrada cuya `etiqueta` sea IGUAL al texto dado
("ALIMENTOS"). No hace falta reinventar ningún formateo: reusar esta
función garantiza que el texto que el developer escribe en el fixture
es EXACTAMENTE el mismo que vería tipeado en el combo real de la UI.
Si no la encuentra, es el error que dispara R13.

### 3.2 Camino real de alta (R10)

Por cada registro del fixture, en el orden de catálogos que dio
`orden_topologico/2` (dependencias primero) y en el orden del propio
archivo dentro de cada catálogo:

1. Resolver cualquier campo tipo "referencia" (3.1).
2. `CatalogoGenerico.crear(schema_mod, :sistema, attrs)` con los
   campos resueltos — el mismo código que ejecuta `POST /api/:tabla`
   hoy. **Corregido 2026-09-17**: `crear/4` YA resuelve sola la
   transición de alta internamente
   (`MetaStateEngine.transicion_alta(catalogo)`, dentro de
   `crear_con_attrs_preparados/5` en `catalogo_generico.ex:396`) —
   `SeedMasterdata` NO la vuelve a buscar por su cuenta, sería
   trabajo duplicado. `scope: :sistema` es el sentinel de
   `Autenticacion.Scope` para "código interno sin usuario humano"
   (`scope.ex:85`) — el mismo que ya usa el resto del motor para
   código sin sesión real (ej. `opciones_referencia/3`). TRN, folio
   (si aplica), `estado_id` de la transición de alta, y reglas
   PRE/POST corren exactamente igual que para un alta real —
   verificado en vivo (Grupo D, tarea 17): `meta_schema_transicion_eventos`,
   `meta_schema_transaction_registry` (TRN real) y
   `meta_schema_auditoria` quedan poblados exactamente como en un
   alta real.

### 3.3 Atomicidad (R13)

Toda la corrida de `mix seed.cargar` (todos los catálogos, todos los
registros de esa corrida) vive dentro de una única `Repo.transaction/1`
externa. La anidación es INEVITABLE, no algo que se pueda evitar
eligiendo qué función llamar: tanto `CatalogoGenerico.crear/2`
(camino `crear_simple`, `catalogo_generico.ex:721`) como
`MetaStateEngine` al ejecutar una transición (`ejecutar_transicion`/
`dar_de_alta`, vía `Ecto.Multi` + `Repo.transaction(multi)` en
`meta_state_engine.ex:620/662/707`) abren su PROPIA transacción
internamente — cualquier alta real, la llame quien la llame, ya
transaciona sola.

Esto en realidad juega a favor de R13, no en contra: el comportamiento
DEFAULT de Ecto/DBConnection para una transacción anidada (sin pasar
`mode: :savepoint` en ningún punto) es que un `Repo.rollback/1`
disparado en CUALQUIER nivel marca la transacción real de Postgres
completa para abortar cuando la transacción MÁS EXTERNA termine — ni
`seed.cargar` ni nadie necesita `mode: :savepoint` (esa opción es
para el caso contrario: querer capturar un error puntual y SEGUIR
adentro de la misma transacción externa, ver
`project_ecto_savepoint_retry` en memoria — justo lo que R13 NO
quiere). `seed.cargar` recorre catálogos/registros con un
`Enum.reduce_while` dentro de su `Repo.transaction/1` externa,
llamando a `CatalogoGenerico.crear/2` por registro; el primer
`{:error, _}` que devuelva alcanza para que `seed.cargar` llame su
propio `Repo.rollback/1` con el detalle — la transacción interna de
`crear/2` ya dejó la transacción real marcada para abortar, la
externa solo formaliza el mensaje de error hacia el developer. Aun
así, se verifica en vivo (Grupo D, tarea 16) antes de confiar en
esto: la memoria `project_ecto_savepoint_retry` advierte
explícitamente que "el sandbox de test enmascara esto" — el
comportamiento real hay que confirmarlo contra Postgres de dev, no
solo contra `mix test`.

## 4. `mix seed.reset` (R14)

**Corregido 2026-09-17** (el diseño original decía "con `--yes`
implícito" — eso hubiera hecho que `seed.reset` NUNCA pida
confirmación, ni una vez, distinto del resto de la herramienta):
`Mix.Tasks.Seed.Reset.run/1` reenvía los MISMOS `args` tal cual a
`Mix.Task.run("seed.vaciar", args)` y, si no reventó (`Mix.raise/1`
es una excepción real — si vacía falla, la ejecución nunca llega a la
línea siguiente), a `Mix.Task.run("seed.cargar", args)`. Como solo
`seed.vaciar` pide confirmación (`seed.cargar` nunca pregunta nada),
reenviar los mismos args ya resuelve "no pedir dos veces" sin
inventar un comportamiento default distinto al de los otros dos
tasks: sin `--yes` pide UNA vez (la de vaciar), con `--yes` ninguna —
mismo criterio en los tres comandos.

## 5. Riesgos / puntos a validar en `tasks.md`

- **Sin `campo_visualizacion` NI `campos_acompanamiento` configurado**:
  `opciones_referencia/1` cae a `"##{id}"` para TODAS las filas de ese
  catálogo — un fixture no puede escribir un id fijo (R11 lo prohíbe
  expresamente, los ids no son estables entre corridas). Si TODAS las
  etiquetas devueltas por `opciones_referencia/1` siguen ese patrón
  (`"#<número>"`), `resolver_referencia/2` debe fallar con un mensaje
  claro ("configurá campo_visualizacion o campos_acompanamiento en
  `<catalogo>` antes de poder referenciarlo desde un fixture"), en vez
  de dejar pasar una coincidencia casual.
- **Transacciones anidadas** (ver 3.3) — **verificado en vivo
  2026-09-17 (Grupo D, tarea 16)**: fixture de 3 registros contra
  `pty_mat_fabricante` (vacío) con el 3° deliberadamente duplicado
  del 1° (unique_constraint real) — los 2 primeros se insertaron sin
  error (`INSERT` + `meta_schema_transicion_eventos` +
  `meta_schema_transaction_registry` + `meta_schema_auditoria`, todo
  real), el 3° falló, `seed.cargar` reportó "Corrida deshecha por
  completo" — y `SELECT count(*) FROM pty_mat_fabricante` confirmó
  **0 filas**: ni siquiera los 2 que "tuvieron éxito" individualmente
  sobrevivieron. El comportamiento default de Ecto/DBConnection
  (sin `mode: :savepoint`) funciona exactamente como predijo §3.3.
- **Rendimiento**: `CatalogoGenerico.crear/2` corre reglas PRE/POST y
  motor de estados por cada fila — para el volumen chico que describe
  esta herramienta (datos de prueba, no miles de filas) no es un
  problema, pero si algún fixture crece mucho conviene medirlo antes
  de asumir que sigue siendo instantáneo.

## 6. Fuera de alcance

Igual que `requirements.md` §0.
