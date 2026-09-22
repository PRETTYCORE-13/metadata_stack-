# SPEC-SYS-1709202602 — Sysadmin / Permission Sets (picker standalone de Permisos por catálogo)

**Documento:** Requirements · **Fase:** ✅ aprobada (2026-09-17, documentación retroactiva), con un incremento real completo después (2026-09-17: el picker de catálogo deja de perder el filtro al asignar un permiso y moverse al siguiente BC — R4 corregido, R4a-b y R9 nuevos, implementados y testeados — ver `tasks.md`).

**Alcance de esta spec**: documentar (retroactivo, ya implementado, sin
tocar código) el uso **standalone** de `MetadataAppWeb.Sysadmin.
CatalogoPermisosLive` en `/sysadmin/catalogos/permisos` (sin catálogo
elegido) y `/sysadmin/catalogos/:recurso/permisos` (con catálogo en la
URL) — la entrada "Permission Sets" del menú, con su propio picker de
catálogo, FUERA de BC Motor.

**Nota de alcance — no duplicar lo ya documentado**: este MISMO
LiveView también vive embebido en el tab "Permisos" de `BcMotorLive`
(`live_render/3`), y ESE uso — la matriz de permisos CRUD +
transiciones por rol, Alcance de Datos (activación y por rol), y sus
2 modos de filtro (Todos los roles / por usuario) — ya está
completamente documentado en
[`SPEC-SYS-1109202605-bc-motor-tab-permisos-alcance`](../SPEC-SYS-1109202605-bc-motor-tab-permisos-alcance/requirements.md)
§2-§5 (R2-R14), con el MISMO código y comportamiento sin ninguna
diferencia entre embebido y standalone. Esta spec NO repite esos
requisitos — solo cubre lo que es exclusivo del uso standalone: cómo
se llega a un catálogo (picker + URL) en vez de estar ya "adentro" de
un BC en BC Motor, y la navegación/chrome alrededor.

La sección "Permisos de detalle por estado" (`SPEC-SYS-1109202605` §6,
R15-R17) **NO existe** en esta pantalla — es exclusiva del wrapper de
`BcMotorLive`, nunca se renderiza en el uso standalone.

Acceso: requiere permiso `"leer"` sobre el recurso
`sysadmin_catalogos_permisos` (mismo mecanismo deny-by-default que el
resto de Sysadmin) o ser `administrador` de la empresa.

## 1. Entrada sin catálogo elegido

R1. CUANDO se navega a `/sysadmin/catalogos/permisos` (sin `:recurso`
en la URL), EL SISTEMA DEBE mostrar el picker de catálogo a la
izquierda vacío de selección y, en el panel principal, el mensaje
"Elegí un catálogo de la izquierda para ver y editar sus permisos." —
sin ninguna matriz de permisos todavía.

## 2. Picker de catálogo

R2. EL SISTEMA DEBE ofrecer, a la izquierda, un buscador de catálogos
por texto — con tope de resultados (mismo patrón de escala que el
resto de RBAC: a +1000 catálogos posibles nunca se carga el universo
entero de una), nunca una lista fija precargada.

R3. CUANDO el buscador tiene resultados y ya hay un catálogo elegido,
EL SISTEMA DEBE resaltar visualmente ese catálogo si aparece entre los
resultados.

R4. CUANDO se elige un catálogo del picker, EL SISTEMA DEBE navegar a
`/sysadmin/catalogos/:recurso/permisos` (la URL cambia, es
compartible/bookmarkeable) **sin perder el estado del picker de la
izquierda** — texto buscado y resultados listados siguen ahí tal cual
estaban (**corregido 2026-09-17, a pedido explícito** — antes esta
navegación remontaba la pantalla entera y vaciaba el picker, obligando
a re-tipear el mismo texto de búsqueda para pasar al próximo catálogo
de una tanda ya filtrada, ej. varios `pty_ch_*` seguidos — "esto genera
más clics y trabajo").

R4a. EL SISTEMA NO DEBE vaciar el texto/resultados del picker como
efecto secundario de elegir un catálogo (R4), conceder/revocar un
permiso, o cualquier otra acción dentro de la matriz de la derecha —
el picker es independiente de esas acciones.

R4b. EL SISTEMA DEBE vaciar el picker ÚNICAMENTE cuando el propio
usuario borra el texto del buscador a mano, o cuando recarga la
página entera (navegación directa a una URL, F5, o primer ingreso) —
son los dos únicos casos donde un picker vacío es lo esperado.

## 3. Catálogo en la URL

R5. CUANDO la URL trae un `:recurso` que existe, EL SISTEMA DEBE cargar
y mostrar ese catálogo (picker a la izquierda + matriz de permisos a
la derecha, ver `SPEC-SYS-1109202605` §2-§5 para el detalle de la
matriz en sí).

R6. CUANDO la URL trae un `:recurso` que NO existe (o ya no existe —
borrado, typo, link viejo), EL SISTEMA DEBE mostrar un flash de error
("Ese catálogo no existe.") y redirigir de vuelta a
`/sysadmin/catalogos/permisos` sin recurso — nunca una pantalla rota o
en blanco.

## 4. Encabezado / navegación

R7. CUANDO hay un catálogo elegido, EL SISTEMA DEBE mostrar en el
encabezado un botón para volver a `/sysadmin/bc-list` y el nombre
visible del catálogo (label, no el nombre técnico) — así se ve siempre
sobre qué catálogo se está parado.

R8. EL SISTEMA DEBE ofrecer esta pantalla también desde el menú
administrativo de Sysadmin, como una entrada de navegación propia
("Permission Sets"), independiente de tener que entrar primero a un
catálogo puntual desde BC List/BC Motor.

## 5. Comodín "*" en el buscador (2026-09-17, a pedido explícito)

R9. CUANDO el texto del buscador del picker es exactamente `*`, EL
SISTEMA DEBE listar catálogos sin exigir ninguna coincidencia de texto
— a diferencia de dejar el buscador vacío (que no lista nada, R2, a
propósito para no mostrar "los primeros N" sin que el admin pidió
nada puntual): `*` SÍ es un pedido explícito de "mostrame lo que
haya". Sigue aplicando el mismo tope de resultados que cualquier otra
búsqueda (R2) — `*` no es una forma de saltarse el límite de escala,
solo de no tener que escribir un prefijo/substring primero.

## 6. Fuera de alcance de esta spec

- La matriz de permisos por rol, sus atajos "Todos"/"Ninguno", el
  filtro por usuario/checkbox de roles de Sysadmin, y todo el modelo de
  Alcance de Datos (activación + por rol) — documentado en
  `SPEC-SYS-1109202605` §2-§5, comportamiento idéntico acá.
- "Permisos de detalle por estado" — no existe en esta pantalla (ver
  nota de alcance arriba).
- El modelo de datos de RBAC en sí (`Permissions`, roles, `can?/3`).
