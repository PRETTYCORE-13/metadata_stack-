# SPEC-TEST-1509202601 — Seed Masterdata (developer mode)

**Documento:** Requirements · **Fase:** ✅ implementada (2026-09-17) — ver `design.md`/`tasks.md` para el detalle de construcción y verificación.

**Alcance de esta spec**: una herramienta de dos fases, exclusiva para
modo developer, que le permite a un desarrollador reiniciar y volver a
poblar sus catálogos de prueba (`pty_*`/`demo100_*`) sin depender de
otra persona (o de la IA) para correr borrados/cargas a mano cada vez
que necesita re-modelar un escenario. Nace de un dolor real de esta
sesión: reconstruir manualmente datos de catálogo repetidamente
mientras se prueban cambios cuesta tiempo y, hoy, tokens.

Primera spec del área `TEST` (herramientas de desarrollo/prueba, a
diferencia de `SYS` que documenta el producto en sí).

## 0. Fuera de alcance (para no repetirlo en cada sección)

- Cualquier tabla que NO sea `pty_*`/`demo100_*` — roles, usuarios,
  empresas, permisos, y cualquier catálogo `meta_schema_*` quedan
  siempre afuera, sin excepción.
- Correr en cualquier ambiente que no sea desarrollo local.
- Una UI de mantenimiento para el fixture de la Fase 2 — decidido en
  conversación previa (2026-09-15): se mantiene como archivo de
  código versionado, editado con el editor normal del developer, no
  con un formulario propio.

## 1. Fase 1 — Borrado ordenado

R1. CUANDO el developer pide reiniciar uno o más catálogos de
desarrollo, EL SISTEMA DEBE vaciar por completo sus datos (ninguna
fila sobrevive) sin alterar la definición/configuración del catálogo
— sus campos, su motor de estados (Activo/Baja/transiciones) y
cualquier otra configuración del BC Motor quedan intactos, listos
para recibir datos nuevos sin tener que reconfigurar nada.

R2. EL SISTEMA DEBE calcular y ofrecerle al developer un orden
sugerido de borrado, basado en las dependencias reales entre los
catálogos elegidos (qué catálogo referencia a cuál) — para que
ninguno se rechace por seguir siendo referenciado por otro que
todavía no se vació.

R3. EL SISTEMA DEBE permitir al developer modificar ese orden
sugerido antes de ejecutar el borrado — la sugerencia automática es
un punto de partida, no una decisión final.

R4. EL SISTEMA DEBE permitir al developer elegir catálogos
específicos por nombre, O pedir "todos los catálogos de desarrollo"
en una sola operación.

R5. EL SISTEMA NUNCA DEBE aceptar como objetivo un catálogo que no
sea de desarrollo (`pty_*`/`demo100_*`) — un intento de nombrar
cualquier otra tabla se rechaza de entrada, sin ejecutar nada.

R6. EL SISTEMA DEBE rechazar ejecutarse fuera del ambiente de
desarrollo local.

R7. ANTES de ejecutar el borrado, EL SISTEMA DEBE mostrarle al
developer exactamente qué catálogos va a vaciar (en el orden
definido) y pedir confirmación explícita.

R8. CUANDO se vacía un catálogo, EL SISTEMA DEBE reiniciar también su
numeración interna de registros, para que los próximos registros
creados vuelvan a nacer desde el principio (mismo efecto que un
catálogo recién estrenado).

## 2. Fase 2 — Carga de datos de prueba

R9. EL SISTEMA DEBE permitir al developer describir, en un archivo
editable fuera de la aplicación (no en la base de datos), qué
registros de ejemplo quiere para cada catálogo — agregar, quitar o
modificar registros de ese archivo es responsabilidad exclusiva del
developer, con su editor de siempre.

R10. CUANDO el developer ejecuta la carga, EL SISTEMA DEBE crear cada
registro pasando por el mismo camino real de alta que usaría un
usuario final o la API (motor de estados, asignación de folio si el
catálogo lo requiere, reglas de negocio del catálogo, generación de
identificadores como TRN) — nunca insertando filas directo en la
tabla.

R11. CUANDO un registro de prueba referencia a otro catálogo, EL
SISTEMA DEBE resolver esa referencia por un valor natural del
registro destino (ej. su descripción/etiqueta), nunca por un id
numérico fijo — los ids no son estables entre una corrida de la Fase
1 y la siguiente.

R12. CUANDO la carga de un catálogo depende de que otro catálogo
referenciado ya tenga sus propios datos cargados, EL SISTEMA DEBE
cargarlos en el orden correcto para que la referencia siempre exista
al momento de crearse.

R13. LA Fase 2 DEBE ser atómica: todo o nada, sin importar cuántos
catálogos o registros abarque una misma corrida. CUANDO un registro
del fixture falla al crearse (ej. una regla de negocio lo rechaza, o
una referencia no se encuentra), EL SISTEMA DEBE deshacer TODOS los
registros ya creados en esa misma corrida (no solo detener los que
faltaban) e informar con precisión cuál registro falló y por qué —
al terminar una corrida fallida, el estado de los catálogos debe ser
idéntico al que tenían antes de empezarla, nunca uno parcialmente
poblado.

## 3. Operación combinada

R14. EL SISTEMA DEBE permitir correr la Fase 1 y la Fase 2 en una
sola operación (reiniciar y repoblar de un saque), o cada fase por
separado según lo que el developer necesite en el momento.

## 4. Preguntas abiertas para `design.md`

Estas no son ambigüedades sin resolver — son decisiones técnicas que
corresponden a la fase de diseño, no a requirements:

- Forma concreta de la herramienta (mix task, script, u otro
  mecanismo) y su interfaz de línea de comandos.
- Formato exacto del archivo de fixture (estructura, un archivo por
  catálogo vs uno solo).
- Cómo se calcula en código el grafo de dependencias de R2/R12
  (mismo mecanismo usado manualmente esta sesión vía
  `information_schema`, o el ya existente en
  `MetaSchemaContext.listar_dependientes/1`).
- Cómo se garantiza la atomicidad real de R13 (una sola
  `Repo.transaction/1` envolviendo toda la corrida de la Fase 2,
  confirmando que efectos colaterales de `crear/2` — folio, TRN,
  reglas — participan de esa misma transacción y revierten limpio).
