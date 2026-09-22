# Design — Despublicar un catálogo huérfano de un ambiente

## Decisión: extraer una función que ya existe, no reinventar nada

Investigando `CatalogoGenerador.eliminar/4` (lo que corre "Eliminar" en
BC List) se encontró que la migración de `DROP` que genera **ya
funciona por nombre, sin depender de que el header exista**:

- `purgar_metadata_por_nombre/1` (`catalogo_generador.ex:216`, YA
  PÚBLICA) resuelve el header por nombre y, si no existe, hace `:ok`
  sin más -- no asume que la fila esté ahí.
- La migración que arma `crear_migracion_drop/1` (hoy privada) hace, en
  su propio `up/0`: `drop_if_exists table(:<nombre>)` +
  `flush()` + `purgar_metadata_por_nombre("<nombre>")`. Corre igual en
  CUALQUIER base donde se aplique -- si el header existe ahí, lo purga
  (cascada real de FK sobre Detail/Estados/Transiciones); si no existe,
  no-opea esa parte y solo dropea la tabla si estaba.

Lo único que falta: `crear_migracion_drop/1` está atada adentro de
`eliminar/4`, que exige `buscar_header/1` (el catálogo tiene que
existir LOCAL) antes de llegar a generarla -- exactamente lo que NO es
cierto para un huérfano como `"historico"`.

Segundo hallazgo, revisando `mix motor.despublicar` (ver
`SPEC-SYS-1009202602` para el precedente con Endpoints): **nunca
chequea si el catálogo es `pty_*`/`demo100_*`** -- solo verifica que no
exista local y que exista un archivo
`priv/repo/migrations/*_eliminar_<catalogo>_*.exs`. Sirve tal cual para
CUALQUIER catálogo, no solo los gitignored -- no hace falta tocarlo.

## Piezas nuevas

1. **`CatalogoGenerador.generar_migracion_drop/1`** -- se saca
   `crear_migracion_drop/1` de adentro de `eliminar/4` y se expone
   como función pública standalone (mismo cuerpo, sin exigir un header
   local). `eliminar/4` pasa a llamar a esta misma función en vez de
   tener su propia copia -- sin duplicar código.

2. **`mix motor.generar_drop_huerfano <catalogo> --confirmar=<catalogo>`**
   (tarea nueva):
   - Confirma que el catálogo YA NO exista local
     (`MetaSchemaContext.obtener_header_por_nombre/1` da `nil`) -- si
     existe, error explícito apuntando a "BC List → Eliminar" (R3).
   - Exige `--confirmar=<catalogo>` tecleado igual al nombre (R5) --
     un flag, no un prompt interactivo (`Mix.shell().yes?/1` es frágil
     en PowerShell/Windows, ya visto hoy con `iex -S mix`).
   - Llama `CatalogoGenerador.generar_migracion_drop/1(catalogo)` --
     escribe el archivo Y lo corre LOCAL ya mismo (limpia cualquier
     tabla física huérfana que también haya quedado local, y confirma
     que la migración compila/corre antes de mandarla a cualquier
     lado).
   - Termina ahí -- no dispara ningún deploy. Deliberado: generar la
     migración y propagarla son pasos distintos, con distintos
     destinos posibles (ver punto 3).

3. **Propagar a un ambiente puntual -- reusa `mix motor.despublicar`
   SIN NINGÚN CAMBIO** (R2): una vez que el archivo de migración existe
   en disco (lo haya generado "Eliminar" de BC List, o el task nuevo
   del punto 2, da igual), `mix motor.despublicar --sistema=<sistema>
   <catalogo>` ya sabe encontrarlo y armar/subir/disparar el bundle --
   nunca miró si el catálogo es `pty_*` o no. Mismo comando para
   `historico` que para cualquier `pty_*`.

4. **Para que quede permanente (no solo en el ambiente elegido en el
   punto 3)** -- si el catálogo NO es `pty_*`/`demo100_*` (no está
   gitignored), la migración generada es un archivo normal: conviene
   además `git add`/commit/push, para que llegue a `testing`/`stable`
   por promoción normal y a cualquier checkout nuevo. Esto es
   RECOMENDADO, no bloqueante -- el paso 3 ya resuelve "ya, ahora, en
   un ambiente puntual" por sí solo.

## Cómo quedan resueltos R1-R5

- **R1** -- `generar_migracion_drop/1` nunca exigió una migración de
  `DROP` previa ni un header local; genera la primera desde cero por
  nombre.
- **R2** -- `mix motor.despublicar --sistema=<sistema> <catalogo>`
  (reusado sin cambios) exige el ambiente explícito, igual para
  `historico` que para un `pty_*`.
- **R3** -- `mix motor.generar_drop_huerfano` rechaza si el catálogo
  todavía existe local, con mensaje explícito.
- **R4** -- `mix motor.despublicar` ya es idempotente (reusado sin
  cambios); la migración en sí también lo es
  (`drop_if_exists`/`purgar_metadata_por_nombre` no-opean si no hay
  nada que borrar).
- **R5** -- `--confirmar=<catalogo>` obligatorio, tiene que coincidir
  con el nombre exacto.

## Riesgo conocido, fuera de esta ronda

No hay una pantalla (LiveView) para esto -- a diferencia de Endpoints
(R73-75), que ya tenía una pantalla de administración donde agregar
botones, "eliminar un catálogo huérfano" es un caso raro/manual que no
justifica hoy una UI dedicada. Queda como mejora futura si se vuelve
frecuente.
