# Requirements — Consulta Directa (diagnóstico de datos)

## Contexto

Esta spec **no es lo mismo que "Reportes"** (la función ya existente,
`schema_context_type = 3`, a veces referida en el código como "Consulta
Ecto") — vale la pena dejarlo explícito porque el nombre "Consulta" ya
está tomado por esa otra función y las dos se confunden fácil:

- **Reportes** (ya existe): un admin arma de antemano qué columnas
  mostrar, con qué etiquetas, qué filtros ofrecer y cómo totalizar —
  pensado para que un usuario de negocio lo abra repetidamente. Vive en
  el árbol de procesos, se publica a producción, respeta RBAC y Alcance
  de Datos como cualquier pantalla normal.

- **Consulta Directa** (esta spec, nueva): una herramienta de
  diagnóstico para un perfil de soporte/consultoría. El escenario típico
  que la motiva: *"un usuario dice que un registro no aparece"* — el
  consultor necesita mirar la tabla directamente, sin curar nada de
  antemano, para confirmar si el registro existe de verdad y por qué no
  se le muestra a ese usuario (la causa más común es el Alcance de
  Datos filtrándolo). Efímera, sin curar, sin publicar — lo opuesto a
  Reportes a propósito.

## Requisitos

**R1.** CUANDO un consultor abre Consulta Directa, EL SISTEMA DEBE
dejarle elegir cualquier catálogo con tabla física propia (maestro o
detalle) para consultar, uno por vez.

**R2.** CUANDO el consultor eligió un catálogo, EL SISTEMA DEBE
ofrecerle filtrar por CUALQUIER columna real de esa tabla — incluidas
las columnas de control/sistema (estado, sucursal, almacén, unidad de
venta, creado por, TRN, fechas de auditoría) que un Reporte normalmente
no expone — con el operador que corresponda a cada tipo de dato,
incluyendo la posibilidad de filtrar por "vacío" / "no vacío".

**R3.** CUANDO el consultor ejecuta una Consulta Directa, EL SISTEMA
DEBE devolver los registros que matchean sin aplicar el Alcance de
Datos del catálogo — el consultor tiene que poder ver un registro sin
importar a qué empresa/sucursal/almacén/unidad de venta pertenece, para
poder confirmar si el problema es justamente que el alcance se lo está
ocultando a otro usuario.

**R4.** CUANDO el consultor lo pide explícitamente, EL SISTEMA DEBE
incluir en el resultado también los registros dados de baja (borrado
lógico) — apagado por default, para que la vista por defecto siga
pareciéndose a lo que ve un usuario común.

**R5.** EL SISTEMA NO DEBE guardar ni publicar ninguna Consulta
Directa como elemento reutilizable — no aparece en el árbol de
procesos, no tiene ficha propia en meta_schema, no viaja por el
pipeline de publicación a producción. Cada uso empieza de cero.

**R6.** EL SISTEMA DEBE mostrar los valores tal como están guardados en
la tabla (incluidos los ids crudos de toda referencia/FK, sin
resolverlos a un nombre legible) — decisión consciente para la primera
versión, a favor de simpleza y de mostrar exactamente lo que hay en la
base sin interpretación.

**R7.** EL SISTEMA NO DEBE permitir ninguna operación de escritura,
actualización o borrado desde Consulta Directa — es exclusivamente de
lectura, igual que Reportes.

**R8.** EL SISTEMA DEBE exigir un permiso propio y distinto de
cualquier permiso ya existente (no el RBAC estándar "leer" de un
catálogo, ni el mismo permiso que ya habilita otras pantallas de
Sysadmin) para poder abrir Consulta Directa — dado que ve datos cruzando
Alcance de Datos y registros dados de baja, tiene que poder concederse
de forma independiente y acotada, solo a quien de verdad cumple ese rol
de soporte/consultoría.

**R9.** CUANDO el resultado de una Consulta Directa supera un volumen
razonable para mostrar en pantalla, EL SISTEMA DEBE paginarlo o
limitarlo — nunca traer una tabla entera sin límite a memoria de una
sola vez.

**R10.** Consulta Directa es una herramienta enteramente NUEVA, no un
cambio a una ya existente — a pedido explícito del usuario (2026-09-09).
EL SISTEMA NO DEBE modificar el comportamiento, el código compartido ni
los datos de Reportes, CatalogoLive, RBAC, Alcance de Datos ni ninguna
otra función ya en uso para construir esto. Toda pieza que Consulta
Directa necesite reusar (por ejemplo, cómo listar/filtrar un catálogo)
se consume tal cual está — si algo compartido necesitara cambiar para
que esto funcione, eso se vuelve a conversar antes de tocarlo, nunca se
asume en silencio.
