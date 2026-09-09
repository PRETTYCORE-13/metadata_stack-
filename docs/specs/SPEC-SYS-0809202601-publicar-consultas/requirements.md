# Requirements — Publicar Consultas a producción

## Contexto

La función **Consulta** (Business Context de solo lectura sobre N tablas,
`schema_context_type = 3`) ya existe y funciona por completo dentro de un
mismo ambiente: motor de ejecución, filtros, etiquetas, RBAC de solo
lectura, árbol de navegación, Get View (vía `ConsultaController`) y banda
de totales configurable, todo ya implementado y en uso.

Lo que falta: cuando se publica el sistema a otro ambiente (producción,
u otro checkout), la definición de la Consulta — su catálogo base, sus
columnas, sus combinaciones con otras tablas y su orden de resultados —
no viaja. Hoy `mix motor.publicar` (que internamente corre
`mix meta.export`) solo exporta el nombre/ícono/visibilidad del elemento
de menú de una Consulta, no su contenido. El resultado: publicar crea el
elemento en el árbol, pero al abrirlo en el ambiente destino no muestra
ningún dato — la Consulta llega vacía, sin que nadie se entere hasta que
alguien la abre ahí.

Esta spec cubre únicamente esa brecha de publicación. No cambia nada del
comportamiento de una Consulta dentro de un mismo ambiente — eso ya
funciona y queda tal cual.

## Requisitos

**R1.** CUANDO se exporta la metadata de la plataforma (publicar a
producción), EL SISTEMA DEBE incluir la definición completa de cada
Consulta existente — su catálogo base, sus columnas, sus combinaciones
con otras tablas y su orden de resultados — junto con el resto de su
configuración (nombre, ícono, visibilidad, ubicación en el menú).

**R2.** CUANDO se publica un ambiente que todavía no tiene una Consulta
dada, EL SISTEMA DEBE crearla completa, con su definición, no solo el
elemento vacío en el menú.

**R3.** CUANDO se publica una Consulta que ya existe en el ambiente
destino, EL SISTEMA DEBE actualizar su definición para que coincida con
la del ambiente de origen, sin duplicar el registro ni dejar una versión
vieja dando vueltas.

**R4.** CUANDO una Consulta depende de un catálogo — como catálogo base o
como una de sus tablas combinadas — que todavía no existe en el ambiente
destino, EL SISTEMA DEBE crear primero ese catálogo y recién después la
Consulta, para que nunca quede publicada apuntando a algo que no existe
todavía.

**R5.** CUANDO se publica una Consulta cuyo catálogo base (o alguna tabla
combinada) fue borrado por completo y ya no existe en ningún lado, EL
SISTEMA DEBE avisarlo claramente en el resultado de la publicación, en
vez de publicarla rota en silencio.

**R6.** CUANDO se elimina por completo una Consulta en el ambiente de
origen, EL SISTEMA DEBE dejar de incluirla en las próximas
publicaciones — mismo comportamiento de limpieza que ya existe hoy para
cualquier catálogo eliminado, sin dejar un archivo huérfano que la
resucite en otro ambiente.
