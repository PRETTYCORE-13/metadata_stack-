# SPEC-SYS-1109202601 — BC Motor: Tab Configuración

**Documento:** Requirements · **Fase:** ✅ aprobada (2026-09-11) — documentación retroactiva. Se actualiza acá primero cuando haya un cambio real que planear sobre el tab.

**Alcance de esta spec**: documentar (retroactivo, ya implementado, sin
tocar código) el tab **"Configuración"** de `BcMotorLive`
(`/sysadmin/bc-list/:tabla/motor`) — el primero y más usado de los
~8 tabs del BC Motor (los otros: Reglas, Diagrama, Contrato, Permisos,
Relaciones, Get Config, Post Config, tienen sus propias specs si hace
falta documentarlos). Cubre, en el orden real en que aparecen en
pantalla: Encabezado, Campos, Estados y Transiciones.

**"Autómata"**: no es una sección propia dentro de este tab — es el
nombre que usa el pedido original para referirse al modelo de estados
+ transiciones que Estados (§3) y Transiciones (§4) configuran juntos.
La representación VISUAL de ese autómata (el grafo) vive en el tab
separado "Diagrama", fuera de esta spec — acá se documenta cómo se
CONFIGURA, no cómo se dibuja.

**Catálogo detalle**: un catálogo con `schema_encabezado_id` (ver
`docs/catalogo-maestro-detalle-requerimientos.md`, R16) nunca tiene
autómata propio — comparte el de su maestro. Para ese caso, este tab
oculta Estados y Transiciones por completo (ver R14) y muestra un
aviso con link al maestro en su lugar.

## 1. Encabezado

R1. CUANDO se abre el tab Configuración de un catálogo, EL SISTEMA
DEBE mostrar un panel "Encabezado" editable con: Etiqueta (nombre
visible), Navegación (carpeta + slug de ruta), Ícono (selector visual
de Material Symbols) y "Es visible" (si aparece en el árbol de
navegación) — mismo componente compartido (`EncabezadoBcComponents`)
que usa el asistente de alta de catálogo nuevo.

R2. CUANDO se guarda el panel Encabezado, EL SISTEMA DEBE persistir
los cambios contra el mismo `meta_schema_header` sin afectar Campos,
Estados ni Transiciones.

## 2. Campos — grid, ordenamiento y referencias

R3. CUANDO se abre el tab Configuración, EL SISTEMA DEBE listar todos
los campos de negocio del catálogo (`meta_schema_detail`) en una
tabla con: nombre técnico, etiqueta (editable inline), tipo,
longitud, Obligatorio (checkbox), Default (valor si llega vacío —
oculto para `referencia` y para campos ya no-obligatorios), "En
tabla" (checkbox — si aparece como columna en el tab Detalle de la
Ficha 360°), Formato (según tipo) y Eliminar.

R4. CUANDO un usuario arrastra la manija de una fila de la tabla de
Campos (`phx-hook="ListaOrdenable"`), EL SISTEMA DEBE reordenar los
campos y persistir el nuevo `orden` de cada uno.

R5. CUANDO el tipo de un campo es `string`, `integer` o `decimal`, EL
SISTEMA DEBE ofrecer un botón "Configurar"/"Configurado" (según si ya
tiene `formato_captura.habilitada`) que abre el formulario de máscara
de captura o formato numérico/moneda.

R6. CUANDO el tipo de un campo es `date` u `hora`, EL SISTEMA DEBE
ofrecer un botón "Configurar"/"Configurado" (según `formato_fecha`)
para su formato de visualización.

R7. CUANDO el tipo de un campo es `referencia`, EL SISTEMA DEBE
mostrar dos acciones independientes en su fila:
- **"Configurar"/"Configurado"** (según si ya tiene
  `campos_acompanamiento`) — abre el formulario de Relación: catálogo
  destino, qué campos trae prestados y cuáles se muestran allá.
- **"Cascada"/"Cascada ✓"** (según si ya tiene `dependencias`) — abre
  el formulario de combo en cascada: qué otro campo referencia de
  este mismo catálogo hay que elegir primero.

R8. CUANDO se hace clic en "Eliminar" en la fila de un campo, EL
SISTEMA DEBE exigir que el usuario TIPEE el nombre técnico del campo
como confirmación (no un simple diálogo sí/no) antes de borrar tanto
la definición (`meta_schema_detail`) como la columna física de la
tabla — operación irreversible, auditada
(`MetaAuditoriaDefinicion.registrar/4`).

R9. EL SISTEMA DEBE ofrecer "+ Agregar campo", que abre un formulario
para dar de alta un campo nuevo (tipo, longitud/precisión según tipo,
opcional, catálogo destino si es referencia, y — si el campo es
obligatorio y no es `referencia` — un "Valor por default" opcional
para backfillear filas ya existentes sin bloquear el alta del campo,
ver `catalogo-maestro-detalle-requerimientos.md` R13).

## 3. Estados

R10. CUANDO el catálogo no es detalle (§ arriba) y tiene al menos un
campo de negocio, EL SISTEMA DEBE habilitar "+ Agregar estado"; si
todavía no tiene ningún campo, el botón queda deshabilitado con la
leyenda "(agregá al menos un campo primero)".

R11. CUANDO se agrega el PRIMER estado de un catálogo, EL SISTEMA
DEBE marcarlo como estado inicial (`es_inicial: true`) de forma
forzada, sin que el usuario pueda desmarcarlo — el formulario lo
muestra como un aviso informativo ("Va a ser el estado inicial..."),
no como un checkbox editable.

R12. CUANDO se agrega el estado NÚMERO 2 en adelante, EL SISTEMA DEBE
ofrecer un checkbox "Es el estado inicial" — marcarlo en uno
desmarca el anterior (a lo sumo un estado inicial vivo por catálogo,
`meta_schema_estados_un_inicial_index`).

R13. LA tabla de Estados DEBE mostrar, por cada estado: color/ícono,
nombre, si es inicial ("Sí"/"—"), orden, y las acciones Editar /
Eliminar — Eliminar solo aparece si el estado NO está referenciado
como origen o destino de ninguna transición existente.

## 4. Transiciones

R14. CUANDO el catálogo no tiene ningún estado con `es_inicial: true`
todavía, EL SISTEMA DEBE deshabilitar "+ Agregar transición" con la
leyenda "(definí un estado inicial primero)".

R15. LA tabla de Transiciones DEBE mostrar, por cada una: acción
(nombre técnico), etiqueta, Origen → Destino (Origen vacío se
muestra como "— (alta)"), cantidad de campos editables, y Editar /
Eliminar.

R16. CUANDO una transición es un self-loop (`estado_origen_id ==
estado_destino_id`, ej. la transición "guardar") y no tiene ningún
campo en `campos_editables`, EL SISTEMA DEBE resaltar su fila y
mostrar un ícono de aviso ("self-loop sin campos_editables — cualquier
intento de editar por acá va a fallar") — no bloquea guardarla, solo
advierte.

R17. LA acción `"guardar"` configurada como self-loop (mismo estado
de origen y destino) ES la única forma de habilitar `PATCH` directo
por API sobre ese catálogo — cualquier otro nombre de acción no lo
activa, documentado como ayuda en el propio formulario.

R18. EL formulario de Alta/Edición de una transición DEBE permitir
elegir Origen (o "— (alta, sin origen) —" para la transición de alta)
y Destino entre los estados vivos del catálogo, más Acción y
Etiqueta.

R19. CUANDO el catálogo es maestro de uno o más catálogos detalle, EL
formulario de transición DEBE organizar "Campos editables" en tabs —
uno por "Encabezado" y uno por cada catálogo detalle — cada tab con
buscador propio y "Todos/Ninguno"; la selección se guarda unificada
sin importar en qué tab quedó parado el usuario al enviar.

R20. CUANDO una transición YA existe (no aplica al crearla — recién
ahí tiene una `accion` definitiva), EL SISTEMA DEBE mostrar, dentro
de su formulario de edición, el estado del permiso RBAC
`{recurso, accion}` para el catálogo maestro y para cada catálogo
detalle que participe de esa transición:
- ✓ en verde si el permiso ya existe (`Permissions.permiso_existe?/2`).
- ⚠ en ámbar ("sin permiso registrado") con un botón "Registrar
  permiso" si falta — un clic lo crea sin salir del modal.

R21. "Registrar permiso" (R20) únicamente ASEGURA que la fila
`{recurso, accion}` exista en `meta_schema_permiso` — es un
prerrequisito, no un otorgamiento: CONCEDER ese permiso a roles
puntuales se sigue haciendo en Roles/Permission Sets, fuera de este
tab. Sin la fila del encabezado, nadie ve/ejecuta la transición ahí
(ni un administrador, no es comodín); sin la fila de un catálogo
detalle, nadie puede mover renglones de esa tabla en esa transición.

## 5. Indicador de completitud (stepper)

R22. EL SISTEMA DEBE mostrar, en la parte superior del BC Motor, una
secuencia de pasos con su estado (completo/pendiente) que refleja en
qué orden real se arma el autómata: Campos → Estado inicial →
Estados → Transiciones → Reglas, más los pasos opcionales que
correspondan (Permisos, Relaciones, Get Config, Post Config) — estos
últimos solo aparecen cuando ya hay algo que mostrar o algo pendiente
de configurar, nunca como ruido permanente.

R23. PARA un catálogo detalle, EL SISTEMA DEBE omitir por completo
los pasos Estado inicial / Estados / Transiciones del stepper (nunca
aplican, mostrarlos como "pendientes" sería engañoso) — conserva
Campos y Reglas.

## 6. Fuera de alcance de esta spec

- El tab "Diagrama" (representación visual del autómata).
- El tab "Contrato" (documentación de API generada).
- El tab "Reglas" (PRE/POST por transición).
- Los tabs "Relaciones", "Get Config", "Post Config" como pantallas
  propias (se mencionan acá solo como entradas del stepper opcional).
- El mecanismo físico de `CatalogoGenerador` para alterar/eliminar
  columnas reales cuando se edita/borra un campo desde este tab.
