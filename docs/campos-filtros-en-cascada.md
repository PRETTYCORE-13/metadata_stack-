# Campos — Filtros en Cascada

Guía práctica de UI: cómo configurar (y diagnosticar) un combo en cascada — un campo tipo `referencia` cuyas opciones dependen de qué se eligió antes en otro campo `referencia` del mismo catálogo (ej. elegís "Línea" y el combo de "Sub-línea" solo muestra las que pertenecen a esa línea). Para el diseño técnico completo ver los comentarios de `MetaSchemaContext.resolver_filtros/3` y `MetaSchemaContext.validar_dependencias_referencia/2` en `lib/metadata_app/business_process_builder/meta_schema_context.ex` — este documento es el "qué click doy", ese es el "por qué funciona así".

## Dónde se configura

**No está en Configuración → Campos.** Está en la pestaña **Relaciones** del Motor del catálogo:

`/sysadmin/bc-list/<catalogo>/motor` → pestaña **Relaciones**

Ahí aparece una fila por cada campo tipo `referencia` que tenga el catálogo, con columna **"Depende de"** y un botón **Cascada**.

## Pasos

1. Andá a `/sysadmin/bc-list/<catalogo>/motor` → pestaña **Relaciones**.
2. Buscá la fila del campo que querés que dependa de otro (ej. "Sublineas") → columna **"Depende de"** → botón **Cascada**.
3. En el bloque "Depende de":
   - **Campo padre**: otro campo `referencia` del MISMO catálogo, el que hay que elegir primero (ej. "Lineas").
   - **Filtrar `<catálogo destino>` por**: un campo del catálogo DESTINO (el que referencia este campo) que también apunte al mismo catálogo que el padre — normalmente el campo `referencia` que ese catálogo destino tiene hacia el catálogo del padre.
4. Guardá.

## El error más común: elegir mal "Filtrar por"

El select "Filtrar `<catálogo destino>` por" lista **todos** los campos del catálogo destino, sin distinguir tipos — es fácil elegir por error un campo de texto (ej. una descripción) en vez del campo `referencia` correcto.

**Regla para no equivocarse**: el campo elegido ahí tiene que guardar el mismo tipo de valor que guarda el campo padre — un id que apunte al mismo catálogo. Si el padre es una `referencia` a "Líneas", el campo elegido en "Filtrar por" tiene que ser, en el catálogo destino, la `referencia` que apunta de vuelta a "Líneas" — nunca un campo de texto, número suelto, ni el mismo campo que se está mostrando en el combo.

### Ejemplo real (Materiales → Línea → Sub-línea)

- Catálogo: `pty_dsd_mat_material` (Materiales).
- Campo `pty_dsd_mat_material_dsd_mat_lineas_sub` ("Sublineas") depende de `pty_dsd_mat_material_dsd_linea` ("Lineas").
- Catálogo destino de "Sublineas": `pty_dsd_mat_lineas_sub`, que tiene un campo `pty_dsd_mat_lineas_sub_dsd_linea` (`referencia` a `pty_dsd_linea`) — **ese** es el que va en "Filtrar por".
- Estaba mal configurado apuntando a `pty_dsd_mat_lineas_sub_descripcion` (texto, "Sub Desc.") — comparaba el id de la línea elegida contra una descripción, así que nunca coincidía.

### Síntomas de esta mala configuración

- El combo del campo hijo (ej. Sub-línea) aparece vacío o sin opciones aunque el catálogo destino sí tenga filas.
- Al guardar, error de campo: *"el valor seleccionado no corresponde a la selección anterior"* — aunque el usuario haya elegido bien ambos campos.

## Resumen

1. Configurar cascada = pestaña **Relaciones** del Motor, botón **Cascada** en la fila del campo hijo — no en Configuración → Campos.
2. "Campo padre" = otro campo `referencia` del mismo catálogo.
3. "Filtrar `<destino>` por" = el campo `referencia` que, DENTRO del catálogo destino, apunta al mismo catálogo que el padre — nunca un campo de texto/descripción.
4. Si el combo hijo sale vacío o el guardado rechaza con "no corresponde a la selección anterior", revisar primero que "Filtrar por" esté apuntando al campo correcto.
