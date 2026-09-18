# SPEC-SYS-1809202602 — Copiar un BC desde BC List

**Documento:** Requirements · **Fase:** ✅ aprobada (2026-09-18).

## 1. Propósito y alcance

Hoy, para reusar la estructura de un catálogo existente en otro nuevo
(mismos campos, mismo tipo de dato, misma referencia), no hay más
camino que armarlo a mano de cero en el wizard "Nuevo catálogo" —
encontrado real hoy: clonar `pty_dsd_cs_vigencias_frec` a
`pty_cs_vigencias_frec` (mismos 4 campos, mismo autómata Activo/Baja)
se hizo a mano por script, lento y propenso a error (renombrar cada
prefijo de campo, resolver referencias propias vs. a otro catálogo,
armar el autómata de nuevo).

Esta spec agrega una acción **"Copiar"** en BC List, junto a
"Editar"/"Eliminar" de cada fila, que clona la ESTRUCTURA de un
catálogo maestro simple bajo un nombre nuevo — nunca sus datos.

**Alcance v1: solo catálogos maestro simples** (`schema_context_type:
1`, sin `schema_encabezado_id`, sin detalles propios que dependan de
él como maestro). Consultas, catálogos detalle, y maestro-detalle
completo quedan fuera de esta primera versión (§7).

## 2. Disparo y datos de entrada

R1. EL SISTEMA DEBE mostrar el botón "Copiar" solo en catálogos
elegibles (ver alcance §1) — oculto en Consultas y en catálogos
detalle, mismo criterio que ya usa "Eliminar" para distinguir esos
casos por fila.

R2. CUANDO se hace clic en "Copiar", EL SISTEMA DEBE abrir un
formulario (modal, mismo patrón que "Nueva carpeta"/"Editar carpeta"
ya usan en BC List) pidiendo, PRE-CARGADOS con los valores del
original pero editables:
- Nombre técnico del catálogo nuevo (`schema_context_name`).
- Etiqueta (`schema_context_label`).
- Carpeta/ruta de navegación (mismo picker de carpeta que "Nuevo
  catálogo").
- Ícono.

R3. EL SISTEMA DEBE validar el nombre nuevo con el mismo criterio que
"Nuevo catálogo" (formato válido, no colisiona con uno existente,
tabla física libre) ANTES de clonar nada — rechazo claro, sin tocar la
base, si falla cualquier chequeo.

## 3. Qué se clona del Header

R4. EL SISTEMA DEBE clonar del Header original, tal cual, TODO lo que
no sea nombre/etiqueta/nav/ícono (ya cubiertos en R2): Alcance de
Datos (`alcance_habilitado`), columnas de control
(`mostrar_*_en_tabla`), `cargar_todos_por_default`,
`orden_columnas_tabla`, `orden_resultados`, transaccional/folio
(`schema_es_transaccional`/`requiere_folio`), visibilidad
(`schema_visible`).

R4a. **Agregado 2026-09-18, bug real encontrado probando "Copiar" sobre
un catálogo transaccional ("Clusters")**: `codigo_trn` es único por
catálogo (constraint de base) y obligatorio cuando
`schema_es_transaccional: true` — CUANDO el original es transaccional,
EL SISTEMA DEBE generarle al clon un `codigo_trn` NUEVO (nunca copiar
el del original, chocaría contra el unique constraint) — mismo
mecanismo que ya usa "Nuevo catálogo" (aleatorio de 4
letras/dígitos, reintentando unas pocas veces si choca contra uno ya
usado por otro catálogo). `requiere_folio` no necesita nada
adicional acá — la asignación real de un perfil de folio es
configuración posterior aparte (Administrador de Folios), no un
requisito de creación del Header.

## 4. Qué se clona de los campos (Detalles)

R5. EL SISTEMA DEBE clonar todos los campos de negocio del original,
renombrando el PREFIJO propio de cada `schema_context_field` (el del
catálogo viejo → el del catálogo nuevo) — ningún campo del clon queda
con el prefijo del original.

R6. CUANDO un campo de tipo "referencia" apunta a SÍ MISMO
(`campos_relacion` con el nombre del propio catálogo), EL SISTEMA DEBE
renombrar esa autoreferencia igual que R5.

R7. CUANDO un campo de tipo "referencia" apunta a OTRO catálogo
(`catalogo`, `campos_acompanamiento`), EL SISTEMA NO DEBE tocar esa
referencia — el clon sigue apuntando al MISMO catálogo referenciado
que el original, nunca lo clona en cascada.

R8. EL SISTEMA NO DEBE clonar ninguna columna/constraint que exista en
la tabla física del original pero no en su metadata actual
(`meta_schema_detail`) — el clon replica la metadata, no un `\d` de la
tabla física. **Caso real confirmado (2026-09-18)**:
`pty_dsd_cs_vigencias_frec` tiene una restricción `EXCLUDE` (Postgres,
anti-traslape de vigencias por operación, `pg_get_constraintdef`
confirmado) que NO viaja al clonar — es SQL crudo, nunca vive en
`meta_schema_detail`. (Corrección sobre una nota anterior de esta
misma spec: la columna `_operacion` en sí SÍ está en la metadata del
original — no es huérfana. La ausencia observada en la primera
inspección fue un artefacto de un `tail -100` que cortó la salida,
no un dato real. La restricción `EXCLUDE` sigue siendo un caso
genuino de "no se clona" — verificado independientemente contra
`pg_constraint`.)

## 5. Qué se clona del autómata (Estados/Transiciones)

R9. CUANDO el original adoptó el motor de estados, EL SISTEMA DEBE
clonar sus Estados y Transiciones tal cual (mismo nombre, orden,
color, acción, origen/destino), renombrando las referencias a campos
propios dentro de `campos_editables` con el mismo criterio de R5 —
una referencia a un campo que ya no existe en el original (huérfana)
NO se copia.

R10. CUANDO el original NO adoptó el motor de estados, EL SISTEMA NO
DEBE inventarle un autómata al clon — nace igual de "sin motor" que el
original.

## 6. Generación física y plantilla

R11. EL SISTEMA DEBE generar la tabla física + módulo Ecto + migración
del catálogo nuevo apenas se confirma la copia (mismo mecanismo que
"Crear catálogo") — nunca queda un catálogo solo en metadata sin tabla
real.

R12. EL SISTEMA DEBE crear la "Plantilla automática" (Post Config) del
catálogo nuevo con los campos ya renombrados — mismo comportamiento
que cualquier catálogo nuevo. NO clona ninguna plantilla CUSTOM
(Vista/Impresión armada a mano en el Constructor) que tuviera el
original — el clon arranca solo con la automática (ver §7).

R13. EL SISTEMA NO DEBE copiar ninguna fila de datos de la tabla del
original — el clon nace con la tabla VACÍA, es una copia de
estructura, nunca de contenido.

R14. EL SISTEMA NO DEBE otorgar ningún permiso sobre el catálogo nuevo
a ningún rol — nace sin acceso otorgado, como cualquier catálogo
nuevo (un admin lo concede después, si corresponde).

## 7. Fuera de alcance de esta spec (v1)

- Copiar Consultas (`schema_context_type: 3`) — no tienen tabla
  física propia, mecanismo distinto.
- Copiar un catálogo DETALLE de forma standalone, o un maestro-detalle
  COMPLETO (maestro + todos sus detalles de un solo clic) — candidato
  a incremento futuro de esta misma spec.
- Clonar plantillas custom del Constructor (Post Config) del
  original, con sus campos renombrados dentro de `definicion` —
  incremento futuro; v1 se conforma con la plantilla automática (R12).
- Publicar el catálogo clonado a ningún sistema — sigue siendo
  `mix motor.publicar` manual, igual que cualquier catálogo nuevo.
