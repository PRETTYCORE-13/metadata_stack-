---
name: pty-patron-sql-view
description: Cómo dar de alta una SQL View (BC tipo 4, "Consulta SQL", nombre técnico pty_sql_<slug>) siguiendo el patrón de SPEC-SYS-2509202601 — un SQL de solo lectura que la plataforma convierte en vista de Postgres y consulta como tabla. Dos usos - Diccionario (columna id entera + descripción, alimenta el combo de un campo referencia de los BC autorizados, con alcance por branch_id/sales_unit_id/inventory_id) y Consulta (reporte de solo lectura en el menú). Cubre alta desde BC List "+ SQL View", escribir y validar el SQL, autorizar BC, conectar el Diccionario en "Filtros" del campo referencia, Contrato/Permisos (solo leer), verificación y publicación. Usar cuando el usuario pide un "diccionario", una "SQL View", una "consulta SQL", un combo filtrado por condiciones que cruzan varios catálogos, o un reporte de solo lectura hecho con SQL.
---

# Patrón SQL View — Diccionario y Consulta

Checklist operativo para dar de alta una **SQL View** (BC tipo 4) tal
como la define SPEC-SYS-2509202601 (`docs/specs/SPEC-SYS-2509202601-consulta-sql/`).
La guía de uso viva es su `05.usage.md` y el diseño es `02.design.md`:
consúltalos antes de volver a explicar algo. Los `file:line` de esta
skill sirven para verificar rápido; si algo cambió, manda el código.

Idea central: el SQL se guarda tal cual y se convierte en una **vista de
Postgres** mediante una migración generada. Después la plataforma la
consulta con Ecto sin schema (`from v in "pty_sql_x"`), como a cualquier
tabla. No se genera ningún módulo `.ex`.

Dos usos, que se eligen en el alta:

- **Diccionario**: lista que alimenta el combo de un campo `referencia`.
  El SQL debe regresar una columna `id` entera (el valor que se guarda)
  y al menos otra columna (la descripción). Siempre **no visible** en el
  menú.
- **Consulta**: reporte de solo lectura. Basta con una columna. Si se
  marca visible, aparece en el menú como tabla paginada.

## Cuándo NO usar este patrón

- Si el combo se resuelve con la cascada o los filtros fijos del campo
  referencia (SPEC-SYS-1109202601 §2.1), no hace falta una SQL View.
  Usa una solo cuando la condición cruza catálogos ("que no exista",
  "suma mayor a", subconsultas, `CASE`).
- Si la pregunta necesita datos que llegan en el momento (parámetros,
  como "precio de este producto para este cliente hoy"), una SQL View
  **no admite parámetros** (R6). Eso está en definición en
  SPEC-SYS-2909202602 (Consulta SQL con parámetros); no lo simules con
  este patrón.
- Una Consulta Ecto (tipo 3, `MetaConsultas`) es otra cosa y esta spec
  no la toca.

## 0. Antes de arrancar — no asumir

Si el usuario no dio alguno de estos datos, pregúntalo antes de tocar la
pantalla; no elijas ninguno en silencio:

| Dato | Si falta, preguntar | Verificar antes de usarlo |
|---|---|---|
| **Uso** | Diccionario o Consulta | — |
| **Etiqueta y navegación** (carpeta + slug) | cómo se llama y dónde vive | que `pty_sql_<slug>` no exista ya (BC List o `priv/repo/catalogos/`); máximo 50 caracteres |
| **El SQL** | la consulta, o la regla de negocio para redactarla | que sea un solo `SELECT`/`WITH … SELECT`, sin parámetros; que las tablas existan en dev |
| **Descripción del combo** (Diccionario) | qué columnas se muestran en el combo | que el SQL las regrese |
| **BC autorizados** (Diccionario) | qué catálogos pueden usarlo | que sean catálogos tipo 1 existentes |
| **Campo destino** (Diccionario) | en qué campo `referencia` se conecta y a qué catálogo apunta | que todos los `id` del SQL existan en ese catálogo destino (R25) |
| **Alcance** | ¿debe acotarse por sucursal, unidad de venta o almacén? | que el SQL exponga `branch_id` / `sales_unit_id` / `inventory_id` si sí |

Reglas para redactar el SQL:

- Nombres de columna solo `^[a-z_][a-z0-9_]{0,62}$`: minúsculas, números
  y guion bajo. Renombra con `AS` lo que no cumpla.
- En Diccionario, `id` es el id del **catálogo destino** del campo, no
  el de una tabla intermedia (R25 lo rechaza si no existe).
- Filtra los registros borrados (`delete_guid IS NULL`) y el estado que
  corresponda. La vista no lo hace por ti.
- Para que se aplique el alcance, expón la columna de control con su
  nombre exacto (`branch_id`, `sales_unit_id`, `inventory_id`). Si no
  se expone ninguna, no se acota y la pantalla lo avisa. El
  administrador siempre ve todo.
- Piensa en volumen: toda ejecución tiene un máximo de 5 s y el combo un
  límite de 500 opciones. Prefiere `NOT EXISTS` a `NOT IN`, filtra por
  columnas con índice y evita agregaciones sobre tablas transaccionales
  completas sin acotar.

## 1. Alta — BC List "+ SQL View"

`/sysadmin/bc-list` → botón **"+ SQL View"**
(`bc_list_live.ex`, `handle_event("abrir_form_sql_view", ...)` ~línea 669).

1. Etiqueta, carpeta y nombre en el menú. La vista previa muestra la
   ruta y el nombre técnico `pty_sql_…`: confírmalo con el usuario.
2. Uso: Diccionario o Consulta.
3. **Crear**. Se crea el encabezado (tipo 4, `schema_visible: false`),
   la fila de `meta_schema_consulta_sql` sin SQL y el permiso `leer`.
   Se abre el editor en `/sysadmin/bc-list/<nombre>/consulta-sql`
   (`consulta_sql_editor_live.ex`).

## 2. Escribir el SQL — tab Configuración

1. Pega la consulta → **Validar y guardar**
   (`ConsultasSql.guardar_sql/2`, `lib/metadata_app/consultas_sql.ex:281`).
2. Primero se valida en una transacción que siempre se revierte:
   `CREATE TEMP VIEW` rechaza todo lo que no sea una lectura y valida
   sintaxis, tablas y columnas. Si falla, se muestra el error de
   Postgres y no se guarda nada. Corrige el SQL y vuelve a intentar;
   no busques rodearlo.
3. Si es válido, se genera y se corre una migración
   `<ts>_vista_pty_sql_<slug>_<ts>.exs` (`DROP VIEW IF EXISTS` +
   `CREATE VIEW`). Cada guardado genera una migración nueva. Queda fuera
   de git (`*pty_*.exs`) y viaja al publicar. **No la edites ni la
   borres a mano.**
4. Revisa en pantalla: **columnas detectadas** (nombre y tipo), **vista
   previa de 5 filas** y el **aviso de alcance**. Confirma con el
   usuario que la vista previa regresa lo que esperaba.

Solo funciona donde está activo `generar_catalogos_en_caliente`
(dev/test). En otros ambientes, la SQL View llega por publicación.

Al editar el SQL de un Diccionario que ya se usa, la nueva versión se
rechaza si pierde `id` o alguna columna que usen los campos (R11). Eso
es lo esperado: ajusta el SQL, no los campos.

## 3. Autorizar BC — solo Diccionario

En la sección **"BC que pueden usarla"** del mismo tab:

1. Busca cada catálogo del paso 0 → **+ Autorizar**
   (`ConsultasSql.autorizar_bc/2`). Se guardan **nombres**, no ids,
   porque viajan entre ambientes.
2. La tabla muestra, por BC, qué campos lo usan ("Sin uso todavía" si
   ninguno), según `ConsultasSql.campos_que_usan/1`.
3. **Quitar** no deja retirar un BC que ya tiene campos usándolo.

## 4. Conectar el Diccionario a un campo referencia

En el **Motor BC del catálogo autorizado** → fila del campo
`referencia` → **Filtros** → sección **"Filtrar por diccionario"**
(`bc_motor_live.ex` ~línea 4366):

1. Elige el Diccionario. Solo aparecen los que tienen uso Diccionario,
   no son visibles, tienen SQL guardado y tienen autorizado este BC.
2. Marca las columnas que forman la descripción del combo (se unen con
   " - ").
3. Opcional: en cada filtro fijo o dependencia, **"Aplicar sobre"** →
   "Columnas del Diccionario" para filtrar contra una columna de la
   vista (ej. la unidad de venta elegida contra `sales_unit_id`).
4. **Guardar**. Se verifica con un anti-join que todos los `id` del
   Diccionario existan en el catálogo destino del campo; si alguno no
   existe, se rechaza.

La metadata queda en `schema_context_properties` del campo:
`"diccionario": {"consulta": "pty_sql_…", "descripcion": [...]}`, sin
migración.

## 5. Contrato y Permisos

- **Contrato**: solo `GET /api/pty_sql_…` con `pagina` y `por_pagina`
  (25 por defecto, máximo 100) y respuesta `meta_campos` / `data` /
  `paginacion`. Nunca `POST`/`PUT`/`DELETE`.
- **Permisos**: solo la acción `leer`, ya registrada en el alta.
  Concédela al rol que corresponda como en cualquier catálogo. No hay
  configuración de alcance por rol: el alcance sale de las columnas de
  control del SQL.
- Tabs en este orden: Configuración, Contrato, Permisos. No hay
  Estados, Transiciones, Reglas ni POST Config: una SQL View no tiene
  autómata ni escribe.

## 6. Visible (solo Consulta)

Si el uso es Consulta y el usuario lo quiere en el menú, marca "Es
visible" en el encabezado. Un Diccionario no puede ser visible mientras
algún campo lo use (R4), y tampoco puede cambiarse a Consulta en ese
caso.

## 7. Verificar de punta a punta

No basta con la vista previa:

- **Diccionario**: abre el formulario real del catálogo autorizado y
  confirma que el combo ofrece solo los registros esperados, con la
  descripción elegida y acotados por el alcance de un usuario **no
  administrador**. Guarda un registro con un valor válido y, por API,
  intenta uno fuera del Diccionario: debe rechazarse con "el valor
  seleccionado no está en el diccionario de este campo".
- **Consulta**: ábrela desde el menú (si es visible) y por
  `GET /api/pty_sql_…` con un rol que tenga `leer` y con uno que no.
- **Dependencias**: intenta eliminar una columna que el SQL usa en su
  catálogo origen; debe rechazarse nombrando la SQL View (R29).
- Si creaste datos de prueba en la base de dev compartida, bórralos al
  terminar.

## 8. Publicar

`mix motor.publicar --sistema=<sistema> pty_sql_<slug>` es un **deploy
real** (GitHub Actions → imagen → servidor), no un commit. Lleva el
encabezado, el bloque `consulta_sql` del `.meta.json` (uso, SQL,
columnas, BC autorizados), las migraciones de la vista y, por
`pg_depend`, los catálogos que su SQL usa. Publicar un catálogo con un
campo que usa un Diccionario también arrastra ese Diccionario. **Nunca
lo corras sin confirmación explícita del usuario y del `--sistema`.**

## Resumen — orden de los pasos

1. Confirmar uso, nombre, SQL, columnas de descripción, BC autorizados,
   campo destino y alcance (preguntar lo que falte).
2. BC List → "+ SQL View" → Crear.
3. Configuración → pegar SQL → Validar y guardar → revisar columnas,
   vista previa y aviso de alcance.
4. Diccionario: autorizar BC → Motor del BC → campo referencia →
   Filtros → "Filtrar por diccionario" → Guardar.
5. Conceder `leer` al rol; Consulta: decidir si es visible.
6. Verificar en real (combo, API, alcance con usuario no admin,
   rechazo de valor inválido, dependencias).
7. Publicar solo con confirmación explícita (es un deploy).
