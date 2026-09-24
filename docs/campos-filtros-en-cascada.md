# Campos — Filtros de un campo referencia (cascada y filtros fijos)

Guía práctica de UI para acotar qué registros se pueden elegir en un campo tipo `referencia`. Hay dos mecanismos, y se pueden combinar:

- **Cascada ("Depende de otro campo")**: las opciones dependen de lo que se eligió antes en otro campo `referencia` del mismo catálogo. Ej.: eliges "Línea" y el combo de "Sub-línea" solo muestra las que pertenecen a esa línea.
- **Filtros fijos**: las opciones se limitan a los registros cuyo campo tenga un valor constante. Ej.: el campo "Almacén" de Repartos solo lista almacenes con `inventory_type = COMPROMETIDA`.

Para el diseño técnico, ver `docs/specs/SPEC-SYS-1109202601-bc-motor-tab-configuracion/` (§3.6 de `02.design.md`) y los comentarios de `MetaSchemaContext.resolver_filtros/3` y `MetaSchemaContext.validar_dependencias_referencia/2`. Este documento es el "qué clic doy"; esos son el "por qué funciona así".

## Dónde se configura

`/sysadmin/bc-list/<catalogo>/motor`, en cualquiera de estos dos lugares (abren el mismo formulario):

- Pestaña **Configuración → Campos**: botón **Filtros** en la fila del campo `referencia`.
- Pestaña **Relaciones**: botón **Filtros** en la fila del campo. Ahí también se ve un resumen en las columnas **"Depende de"** y **"Filtros fijos"**.

El botón dice **"Filtros ✓"** cuando el campo ya tiene configurada una cascada o algún filtro fijo. (Hasta 2026-09-24 se llamaba "Cascada".)

## Cascada — pasos

1. Abre **Filtros** en la fila del campo que debe depender de otro (ej. "Sublineas").
2. En la sección **"Depende de otro campo"**, usa **+ Agregar dependencia**:
   - **Campo padre**: otro campo `referencia` del MISMO catálogo, el que hay que elegir primero (ej. "Lineas").
   - **Filtrar `<catálogo destino>` por**: el campo del catálogo DESTINO que apunta al mismo catálogo que el padre. El select solo ofrece campos `referencia` compatibles.
   - **Obligatorio**: si está marcado, el campo queda deshabilitado hasta elegir el padre.
3. Guarda.

### Ejemplo real (Materiales → Línea → Sub-línea)

- Catálogo: `pty_dsd_mat_material` (Materiales).
- Campo `pty_dsd_mat_material_dsd_mat_lineas_sub` ("Sublineas") depende de `pty_dsd_mat_material_dsd_linea` ("Lineas").
- Catálogo destino de "Sublineas": `pty_dsd_mat_lineas_sub`, que tiene un campo `pty_dsd_mat_lineas_sub_dsd_linea` (`referencia` a `pty_dsd_linea`). **Ese** es el que va en "Filtrar por".

### Si algo no cuadra

- El combo hijo aparece vacío aunque el destino sí tenga filas, o al guardar sale *"el valor seleccionado no corresponde a la selección anterior"* aunque se eligieron bien los dos campos: revisa que "Filtrar por" apunte al campo `referencia` correcto del destino.

## Filtros fijos — pasos

1. Abre **Filtros** en la fila del campo (ej. "Almacén" en Repartos).
2. En la sección **"Filtros fijos"**, usa **+ Agregar filtro fijo**:
   - **Campo de `<catálogo destino>`**: la columna del destino que se va a comparar (ej. `inventory_type`). También funciona con tablas de sistema como Almacén, Sucursal o Unidad de venta.
   - **Valores permitidos**: uno o varios, separados por coma (ej. `COMPROMETIDA` o `COMPROMETIDA, DISPONIBLE`). Mientras escribes, el campo sugiere los valores que ya existen en esa columna y debajo se listan.
3. Guarda.

Reglas:

- No distingue mayúsculas ni espacios de más: `comprometida` y ` COMPROMETIDA ` son lo mismo. Los valores se guardan en mayúsculas.
- Con varios valores en un filtro, basta con que coincida uno. Con varios filtros, se tienen que cumplir todos.
- Un registro con ese campo vacío nunca aparece.
- Se suma a la cascada y al filtro automático por sucursal activa (almacenes y unidades de venta solo de la sucursal activa).
- Al guardar un registro, por pantalla o por API, el servidor rechaza un valor que no cumpla el filtro con *"el valor seleccionado no cumple los filtros configurados para este campo"*. Solo se revisa cuando ese campo cambió, así que los registros guardados antes de configurar el filtro se pueden seguir editando.
- Para quitar el filtro, bórralo con el ícono de basura y guarda.
- Viaja al publicar el catálogo (`mix motor.publicar`), también si el campo ya existía en el destino.
