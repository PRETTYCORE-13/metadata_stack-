# Pasos — Crear un catálogo Maestro-Detalle

Guía práctica de UI: cómo armar un maestro con uno o más catálogos detalle (ej. un empleado con sus funciones, un pedido con sus items), de punta a punta, sin saltarse el paso que más se olvida. Para el diseño técnico completo (qué resuelve cada pieza del motor, por qué) ver `docs/catalogo-maestro-detalle-requerimientos.md` — este documento es el checklist de "qué click doy y en qué orden", ese es el "por qué funciona así".

## 1. Creá el catálogo MAESTRO primero

`/sysadmin/bc-list/nuevo-completo` → armalo como cualquier BC normal: sus campos, y si el negocio lo pide, sus propios Estados/Transiciones. Este es el encabezado (ej. `pty_dsd_empleados`).

## 2. Creá el catálogo DETALLE, apuntando al maestro

Mismo asistente (`/sysadmin/bc-list/nuevo-completo`) — en el campo **"Si este catálogo es el detalle de otro"** elegí el maestro que acabás de crear.

Definile sus propios campos (metacampos) normal, pero **no le definas Estados/Transiciones propias**: un catálogo detalle nunca tiene autómata propio, comparte el del maestro. La UI lo recuerda con un aviso apenas elegís el maestro.

## 3. Habilitá qué campos del detalle se pueden tocar por transición

En el Motor del **maestro** (`/sysadmin/bc-list/<maestro>/motor`) → pestaña Estados/Transiciones → para cada transición que vaya a tocar renglones (típicamente "Guardar"), agregá a **"Campos editables"** los campos del catálogo detalle que querés poder crear/editar desde ahí.

Sin esto, un renglón nuevo o editado con esos campos se rechaza por venir fuera de la whitelist de la transición.

## 4. "Permisos de detalle" — el paso que más se olvida

Mismo Motor del maestro → pestaña **Permisos** → tabla de abajo, **"Permisos de detalle"**. Una fila por Estado del maestro, y por cada catálogo detalle 3 casilleros: Insertar / Actualizar / Borrar.

**Deny-by-default real**: sin tildar nada acá, nadie —ni un usuario `super_admin`— puede insertar, editar ni borrar renglones en ese estado, sin importar qué permiso RBAC tenga su rol. Es una capa aparte, independiente de RBAC.

Tildá al menos **Insertar** en los estados donde tenga sentido cargar renglones (ej. "Activo"). Si además el negocio necesita editar o quitar renglones existentes desde ese estado, tildá también Actualizar/Borrar — son independientes entre sí.

> Si en cualquier punto de acá en adelante te rechaza con `encabezado_id: el estado actual no permite insertar renglones en '<catalogo>'`, es este paso: falta la fila de permiso para esa combinación exacta de Estado × catálogo detalle.

## 5. Permisos RBAC normales

Misma pestaña Permisos, la matriz de arriba:

- Sobre el catálogo **detalle**: concedé "crear"/"leer"/"editar" al rol que corresponda. No hay "eliminar" real para un detalle — un renglón nunca se borra técnicamente, solo transiciona a un estado tipo "Cancelado" (o el que el negocio defina).
- Sobre el **maestro**: el permiso **"guardar"** para ese mismo rol — es el que gatea el flujo completo de "Guardar" desde la Ficha 360°, incluso cuando lo único que cambió son renglones nuevos (sin tocar ningún campo del encabezado).

## 6. (Opcional) Reglas propias del detalle

El catálogo detalle conserva su propia pestaña **"Reglas"** en su Motor (`/sysadmin/bc-list/<detalle>/motor`) — es la única pestaña útil que le queda (Diagrama/Contrato no aplican, un detalle no tiene autómata ni documentación de API propios).

Ahí podés exigir campos obligatorios por transición del renglón, con el mismo vocabulario que cualquier catálogo:

```elixir
MetaStateEngine.Reglas.Pre.evaluar("campos_requeridos", registro, contexto, %{"campos" => [...]})
```

o cualquier otra validación de negocio por renglón (ej. "la cantidad no puede superar el stock").

## 7. Probalo en la Ficha 360°

Un registro del maestro (`/registro/<maestro>/nuevo` para uno nuevo, o `/registro/<maestro>/<id>` para uno existente) → pestaña **"Detalle"** → ahí se agregan/editan/quitan renglones con el grid tipo Excel, todo junto con el botón "Guardar" del encabezado — un solo click persiste encabezado + renglones nuevos/editados/quitados a la vez.

## Resumen — orden de los 7 pasos

1. Crear el maestro (BC normal, con o sin autómata propio).
2. Crear el detalle, con "encabezado_de" apuntando al maestro — sin Estados/Transiciones propias.
3. Campos editables por transición del maestro (incluir los campos del detalle que apliquen).
4. Permisos de detalle por Estado × catálogo detalle (Insertar/Actualizar/Borrar) — deny-by-default.
5. Permisos RBAC (crear/leer/editar sobre el detalle, "guardar" sobre el maestro).
6. Reglas propias del detalle (opcional).
7. Probar desde la Ficha 360°, pestaña Detalle.
