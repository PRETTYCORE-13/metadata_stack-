# Requirements — La importación por Excel también actualiza registros existentes

## Contexto

Hoy el módulo de Importación de Datos (`MetaImportacionDatos`) solo
sabe dar de alta: toda fila del Excel pasa por el mismo camino de
creación, sin importar si ya existe un registro parecido. Si una fila
coincide con un registro ya existente (típicamente porque el catálogo
tiene un índice único), la importación la rechaza como error — nunca la
actualiza. Si el catálogo no tiene ningún campo único, en cambio, crea
un duplicado.

Esta spec agrega el camino que falta: que una fila cuyo identificador ya
existe actualice ESE registro en vez de crear uno nuevo o rechazarlo.

Pieza existente clave para esto: hoy ya existe el concepto de "campo
identificador del encabezado" (ej. Folio), pero **solo se configura
cuando la plantilla tiene catálogos detalle activados** — sirve
únicamente para vincular la hoja de encabezado con las de detalle. Para
que la actualización funcione en CUALQUIER plantilla (tenga detalle o
no), ese mismo campo tiene que poder configurarse también en plantillas
simples de un solo catálogo.

**Corrección a pedido explícito (2026-09-09):** la primera versión de
R7 decía que actualizar un encabezado reemplaza TODOS sus renglones
existentes por los del archivo — es decir, un renglón viejo que no
aparece en el Excel nuevo se borra. Caso real que esto rompía: un
encabezado con 20 renglones donde solo se quiere actualizar 1 —
reemplazar todo habría borrado los otros 19 sin que nadie lo pidiera.
R7 queda corregido más abajo: cada renglón se actualiza/crea de forma
individual, nunca se borra ninguno implícitamente por el solo hecho de
no aparecer en el archivo. Para poder identificar UN renglón puntual
dentro de varios (y no tocar los demás), cada catálogo detalle activado
en la plantilla necesita también su propio campo identificador —
análogo al del encabezado, pero a nivel de renglón (ej. el código de
producto de esa línea).

## Requisitos

**R1.** EL SISTEMA DEBE permitir configurar un campo identificador en
cualquier plantilla de importación, tenga o no catálogos detalle
activados — hoy esa opción solo aparece cuando hay detalle.

**R2.** CUANDO una plantilla tiene un campo identificador configurado y
el valor de una fila coincide EXACTAMENTE con el de un registro ya
existente (que no esté dado de baja), EL SISTEMA DEBE actualizar ese
registro en vez de crear uno nuevo.

**R3.** CUANDO una plantilla tiene un campo identificador configurado y
el valor de una fila no coincide con ningún registro existente, EL
SISTEMA DEBE crear un registro nuevo — igual que el comportamiento
actual.

**R4.** CUANDO el valor del campo identificador de una fila coincide
con más de un registro existente, EL SISTEMA DEBE rechazar esa fila
como error por ambigüedad, sin actualizar ninguno de los que matchean.

**R5.** CUANDO una plantilla no tiene ningún campo identificador
configurado, EL SISTEMA DEBE comportarse exactamente igual que hoy:
toda fila se trata como alta, sin buscar coincidencias — este cambio no
debe alterar ninguna plantilla que no configure el campo nuevo.

**R6.** CUANDO se actualiza un registro existente, EL SISTEMA DEBE
reemplazar el valor de cada campo que trae la plantilla con lo que
venga en la fila — incluida una celda vacía, que deja el campo vacío.
No es una actualización parcial: la fila reemplaza el registro
completo en los campos que la plantilla expone.

**R7.** (Corregido — ver nota en Contexto) EL SISTEMA DEBE permitir
configurar un campo identificador propio para cada catálogo detalle
activado en una plantilla, además del identificador del encabezado.

**R7.1.** CUANDO se actualiza un encabezado y una fila de detalle del
archivo tiene un identificador de renglón que coincide con un renglón
ya existente de ESE encabezado, EL SISTEMA DEBE actualizar ese renglón
puntual (mismo criterio de reemplazo de campos que R6).

**R7.2.** CUANDO una fila de detalle del archivo tiene un identificador
de renglón que no coincide con ningún renglón existente de ese
encabezado, EL SISTEMA DEBE crear un renglón nuevo — igual que hoy.

**R7.3.** EL SISTEMA NO DEBE eliminar ni modificar ningún renglón
existente que el archivo no mencione — actualizar un encabezado nunca
borra un renglón por el solo hecho de estar ausente del archivo. Si en
algún caso sí hace falta eliminar renglones existentes de forma masiva,
eso queda fuera del alcance de esta spec y se resuelve por otro medio.

**R7.4.** CUANDO un catálogo detalle activado en la plantilla no tiene
su propio campo identificador configurado, EL SISTEMA DEBE tratar
todas sus filas como alta de renglón nuevo, sin buscar coincidencias —
mismo criterio de "sin identificador, sin cambios" que R5 aplica al
encabezado.

**R7.5.** CUANDO el identificador de una fila de detalle coincide con
más de un renglón existente de ese encabezado, EL SISTEMA DEBE
rechazar esa fila como error por ambigüedad — mismo criterio que R4.

**R8.** La previsualización (antes de confirmar la importación) DEBE
mostrar, para cada fila (de encabezado y de detalle), si el resultado
va a ser una creación o una actualización y sobre qué registro
existente — para que quien importa entienda el impacto antes de
confirmar, en especial porque actualizar sobrescribe los campos que la
plantilla expone (R6).

**R9.** El resto del comportamiento actual de la importación se
mantiene sin cambios: validación fila por fila con el mismo motor de
siempre, atomicidad de encabezado+renglones (si algo falla, esa fila
completa se rechaza sin abortar las demás), previsualización sin
persistir nada, y mensajes de error con sugerencia. Esta spec agrega el
camino de actualización, no reemplaza el de alta.

## Restricción real del motor, encontrada durante la investigación (2026-09-09)

Editar campos de un registro ya existente (de encabezado o de un
renglón) hoy está gobernado por reglas propias del motor de estados,
independientes de la importación — son las MISMAS reglas que ya limitan
qué se puede editar a mano desde la Ficha. En particular:

- Editar un campo de un renglón que YA EXISTE (no crearlo, editarlo)
  SIEMPRE pasa por la transición "Guardar" del maestro — es una regla
  de cumplimiento (CompliancePty C6), no algo que esta spec pueda pasar
  por alto. Sin esa transición configurada, no hay forma de editar un
  renglón existente, ni a mano ni por importación.
- Agregar un renglón NUEVO a un encabezado ya existente es una
  operación aparte que NO depende de "Guardar" — se puede hacer aunque
  el catálogo no tenga esa transición.
- Qué campos del encabezado se pueden editar depende del estado actual
  del registro y de la configuración del catálogo — un catálogo que
  adoptó el motor de estados pero no tiene "Guardar" puede terminar sin
  NINGÚN campo editable por fuera de una transición real, incluso para
  el encabezado.

Para no duplicar ni arriesgar desalinearse de esa lógica (que puede
cambiar), el requisito clave es de comportamiento, no de mecanismo:

**R10.** LA IMPORTACIÓN NUNCA DEBE poder actualizar un campo (de
encabezado o de un renglón existente) que la edición manual del
registro (Ficha) tampoco podría editar en su estado actual — la
importación reusa las mismas reglas de edición que ya existen, nunca
un camino nuevo que las evite.

**R11.** CUANDO una fila de actualización choca con la regla de R10 (un
campo, un renglón, o el catálogo entero no admite esa edición ahora
mismo), EL SISTEMA DEBE rechazar esa fila con un mensaje que explique
la causa real (qué campo/renglón no se pudo tocar y por qué) — nunca
fallar en silencio ni degradar a una alta o a un no-op sin avisar.

**R12.** Agregar un renglón nuevo a un encabezado ya existente (fila de
detalle sin identificador que matchee ninguno existente, R7.2) NO
depende de que el catálogo tenga la transición "Guardar" configurada —
esa restricción (R10/R11) aplica solo a editar un renglón que ya existe
(R7.1) y a editar campos del propio encabezado.
