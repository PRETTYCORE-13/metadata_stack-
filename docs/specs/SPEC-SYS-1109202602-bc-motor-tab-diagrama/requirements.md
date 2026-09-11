# SPEC-SYS-1109202602 — BC Motor: Tab Diagrama

**Documento:** Requirements · **Fase:** ✅ aprobada (2026-09-11) — documentación retroactiva + 1 fix real (R10, ver `tasks.md`). Verificación interactiva en navegador todavía pendiente (`tasks.md` Grupo B, tarea 7).

**Alcance de esta spec**: documentar (retroactivo, ya implementado,
sin tocar código) el tab **"Diagrama"** de `BcMotorLive`
(`/sysadmin/bc-list/:tabla/motor`) — la representación visual
(grafo de estados/transiciones) del autómata que se CONFIGURA en el
tab "Configuración" (ver `SPEC-SYS-1109202601-bc-motor-tab-configuracion`).
Esta spec es puramente de lectura: el tab Diagrama no tiene ningún
control de edición propio, solo dibuja lo que ya existe.

**Relación con el resto del módulo BC Motor**: mismo LiveView
(`BcMotorLive`), mismo dato fuente (`estados`/`transiciones` del
header) — esta es la segunda de N specs sobre los tabs de este motor
(la primera: Configuración). Usar el prefijo **"BC Motor"** en el
título de cada una para que el conjunto se identifique como un solo
módulo en el listado de `docs/specs/`.

## 1. Visibilidad del tab

R1. EL SISTEMA DEBE mostrar el tab "Diagrama" únicamente para
catálogos que NO son detalle (`schema_encabezado_id` nulo) — un
catálogo detalle nunca tiene autómata propio (comparte el de su
maestro, ver R3 de `catalogo-maestro-detalle-requerimientos.md`), así
que el tab ni siquiera aparece en la barra para ese caso.

## 2. Generación de la definición del diagrama

R2. CUANDO se carga o recarga el motor de un catálogo (alta,
edición o eliminación de cualquier estado/transición), EL SISTEMA
DEBE regenerar la definición completa del diagrama en formato Mermaid
(`stateDiagram-v2`) a partir de TODOS los estados y transiciones
vivos del catálogo — nunca un diff incremental.

R3. LA definición DEBE declarar cada estado con un alias corto
(`e1`, `e2`, ...) en vez de usar el nombre real como identificador de
nodo — evita romper la sintaxis de Mermaid con nombres que traen
espacios o acentos. La etiqueta visible del nodo combina orden +
nombre (`"<orden> - <nombre>"`).

R4. LA definición DEBE dibujar un arco `[*] --> <estado>` por cada
estado marcado `es_inicial: true` — el punto de entrada estándar de
un diagrama de estados.

R5. LA definición DEBE dibujar un arco por cada transición,
etiquetado con su `accion` — el origen es el alias del estado
correspondiente, o el nodo `[*]` cuando la transición no tiene
`estado_origen_id` (transición de alta).

R6. CUANDO un estado tiene un color configurado (mismo color que se
ve como punto en la tabla de Estados del tab Configuración), EL
SISTEMA DEBE aplicar ese color de relleno al nodo correspondiente en
el diagrama, con el color de texto (claro/oscuro) calculado
automáticamente para que siga siendo legible sobre ese fondo.

## 3. Renderizado

R7. EL SISTEMA DEBE renderizar la definición Mermaid como SVG en el
navegador, usando una copia local de la librería (sin depender de una
CDN externa) — se carga una sola vez por sesión de página y se
reutiliza para cualquier otro diagrama Mermaid que la misma página
necesite dibujar.

R8. MIENTRAS el diagrama todavía no terminó de renderizar, EL
SISTEMA DEBE mostrar el texto "Cargando diagrama…" en el lugar donde
va a aparecer el SVG.

R9. SI el renderizado de Mermaid falla (definición inválida, error
de la librería), EL SISTEMA DEBE mostrar el texto "No se pudo dibujar
el diagrama." en vez de dejar el contenedor vacío o congelado en
"Cargando…", y registrar el error en la consola del navegador para
diagnóstico.

## 4. Refresco en vivo

R10. CUANDO el diagrama ya está dibujado y `@diagrama` cambia del
lado servidor (alta/edición/borrado de cualquier estado o transición
mientras el tab Diagrama sigue montado, o al volver a él sin
recargar la página), EL SISTEMA DEBE redibujarlo automáticamente con
la definición nueva, sin requerir F5 ni navegar fuera del catálogo.

**Corregido 2026-09-11** (bug real encontrado al documentar esta
spec, no un requisito nuevo): el hook `DiagramaMotor` solo dibujaba
en `mounted()` — `phx-update="ignore"` congela el CONTENIDO del
`<div>` para LiveView (necesario, si no cada re-render pisaría el SVG
que Mermaid ya inyectó), pero el elemento SIGUE recibiendo sus
propios atributos actualizados (`data-diagrama`) en cada diff, y eso
dispara igual el callback `updated()` del hook — que simplemente no
existía. Agregado `updated()` (redibuja solo si `data-diagrama`
cambió de verdad, comparado contra la última definición pintada, para
no re-renderizar Mermaid en cada `updated()` que no toque este div)
— ver `design.md` §4.

## 5. Fuera de alcance de esta spec

- Edición de estados/transiciones (documentado en
  `SPEC-SYS-1109202601-bc-motor-tab-configuracion`).
