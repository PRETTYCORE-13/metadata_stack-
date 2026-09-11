# SPEC-SYS-1109202601 — BC Motor: Tab Configuración

**Documento:** Design · **Fase:** ✅ aprobada (2026-09-11).

Documentación retroactiva — describe el mecanismo tal como existe hoy
en `lib/metadata_app_web/live/sysadmin/bc_motor_live.ex` (LiveView
único, ~4700 líneas, todos los tabs del BC Motor incluidos) +
`lib/metadata_app_web/live/encabezado_bc_components.ex` (panel
Encabezado, compartido con el asistente de alta) +
`lib/metadata_app/meta_estados_admin.ex` (contexto de
estados/transiciones) + `lib/metadata_app/business_process_builder/catalogo_generador.ex`
(alta/baja de columnas físicas).

## 1. Módulo y montaje

`BcMotorLive` monta con `header = MetaSchemaContext.obtener_header_por_nombre(tabla)`
en `mount/3` y arma TODOS los assigns de TODOS los tabs de una — no
hay carga perezosa por tab; cambiar de tab (`tabs_motor`, JS 100%
cliente, `display:none` sobre los paneles) no dispara ningún
`handle_event` ni round-trip al servidor. `@es_detalle?` se calcula
una vez (`header.schema_encabezado_id != nil`) y gatea qué tabs se
muestran en la barra (ver R14 de requirements — "Estados"/
"Transiciones" ni siquiera aparecen como opción de tab para un
catálogo detalle).

## 2. Encabezado (R1-R2)

`EncabezadoBcComponents` es un módulo de función-components +
helpers puros, sin `GenServer` propio — `BcMotorLive` y
`BcNuevoCompletoLive` lo usan como librería:

- `form_desde_header/1` arma el mapa de assigns inicial.
- `panel/1` (function component) renderiza Etiqueta/Navegación/
  Ícono/Visible — Navegación descompuesta en "carpeta" (select con
  las carpetas existentes del árbol) + "slug" final, para no dejar
  tipear la ruta completa a mano (bug real corregido, ver comentario
  en el módulo).
- `guardar/2` valida y llama `MetaSchemaContext.actualizar_header/2`
  — el mismo `meta_schema_header` que ya usa el resto del sistema,
  sin tabla ni proceso aparte.

`handle_event("guardar_header", ...)` en `BcMotorLive` delega 100% a
`EncabezadoBcComponents.guardar/2` y recarga `@header` en éxito.

## 3. Campos (R3-R9)

### 3.1 Origen de datos

La tabla sale de `@campos` = `MetaSchemaContext.listar_detalles(tabla)`
(filas de `meta_schema_detail`, cada una con `schema_context_field` +
`schema_context_properties` JSONB) ordenadas por la clave `"orden"`
de las propiedades. Cada columna editable de la tabla (etiqueta,
obligatorio, valor default, "en tabla") es su propio `<form
phx-change="...">` de un solo campo — cada tecla/click dispara un
evento independiente y chico, sin un formulario grande con estado
compartido.

### 3.2 Ordenamiento drag-and-drop (R4)

`<tbody phx-hook="ListaOrdenable" data-grupo="campos-catalogo">` — el
hook (`ListaOrdenable`, definido en `assets/js/app.js`, reusado
también por la tabla de Get View con otro `data-grupo`) envuelve la
librería Sortable.js sobre la manija `.jal-manija`; al soltar, emite
un único `pushEvent("mover_a", {id, contenedor_id, index})` con SOLO
el item movido y su nueva posición — no la lista completa.
`handle_event("mover_a", %{"id" => id, "index" => index}, socket)`
reconstruye el orden completo del lado servidor (toma el orden actual
de `@campos`, saca `id` y lo reinserta en `index`) y llama
`MetaSchemaContext.reordenar_campos/2` — puramente metadata
(`"orden"` en `schema_context_properties`), no toca la columna física
ni dispara `CatalogoGenerador.generar/1`. `@campos` ya sale ordenado
por `"orden"` desde `listar_detalles/1`, así que recargar el motor
alcanza para reflejar el nuevo orden.

### 3.3 Botones "Configurar" por tipo (R5-R7)

`abrir_form_formato` / `abrir_form_formato_fecha` / `abrir_form_relacion`
/ `abrir_form_dependencia` abren cada uno su propio modal
(`assign(:form_activo, ...)`), todos leyendo/escribiendo dentro del
mismo `schema_context_properties` JSONB del campo — no hay tablas
nuevas por tipo de configuración:

| Botón | Propiedad que lee para "¿Configurado?" | Qué guarda |
|---|---|---|
| Formato (string/integer/decimal) | `formato_captura.habilitada` | máscara/formato numérico |
| Formato (date/hora) | `formato_fecha` | patrón de fecha/hora |
| Relación (solo referencia) | `campos_acompanamiento` | catálogo destino + campos prestados/mostrados |
| Cascada (solo referencia) | `dependencias` | `[{"campo_padre": "...", ...}]` |

`panel_relaciones/1` (sección "Relaciones", **tab separado**, fuera
de esta spec) es la MISMA información que la columna "Relación" de
esta tabla, en formato tabla dedicada — reusa `abrir_form_relacion`/
`abrir_form_dependencia`, no duplica lógica.

### 3.4 Eliminar campo (R8)

`abrir_eliminar_campo` abre un modal que exige tipear el nombre
técnico del campo (`@eliminar_campo_form.confirmar_texto`) —
`handle_event("confirmar_eliminar_campo", ...)` llama
`CatalogoGenerador.eliminar_campo/4`:

1. `validar_confirmacion/2` — rechaza si el texto tipeado no
   coincide exacto con el nombre del campo.
2. `MetaSchemaContext.eliminar_detalle/1` — borra la fila de
   `meta_schema_detail`.
3. `quitar_columna/2` — genera y corre una migración `ALTER TABLE ...
   DROP COLUMN` (irreversible, mismo patrón "migración hacia
   adelante con timestamp" que el resto del generador).
4. `asegurar_campos_nuevos/1` — resincroniza el `.ex` del schema
   generado para que dejen de existir referencias al campo borrado.
5. `MetaAuditoriaDefinicion.registrar/4` — deja rastro en la
   auditoría de definición (quién/cuándo borró qué campo).

### 3.5 Agregar campo (R9)

`abrir_form_campo` abre el modal de alta (`FieldDesignerComponents`,
el mismo "asistente" reusado desde el wizard de catálogo nuevo).
`handle_event("guardar_campo_asistente", ...)` →
`FieldDesignerComponents.construir_propiedades/3` (valida y arma el
mapa de `schema_context_properties`) → `guardar_campo_y_generar/4`:

1. `MetaSchemaContext.agregar_detalle/2` — crea la fila de
   `meta_schema_detail` dentro de una transacción.
2. `CatalogoGenerador.generar/1` — la MISMA función que crea un
   catálogo nuevo desde cero; sobre un catálogo que ya existe toma la
   rama "retrofit" (`asegurar_*`) y corre el `ALTER TABLE ... ADD
   COLUMN` correspondiente.
3. Si el generador falla, la transacción entera revierte (no queda
   metadata húerfana sin columna física, ni viceversa) — ver
   `transaccion_con_generador/2`.

"Valor por default" (solo si obligatorio y tipo ≠ referencia) usa
`null: false, default: <valor>` real de Postgres — filas viejas se
backfillean por el motor de defaults de Postgres 11+, sin reescribir
la tabla fila por fila (documentado con detalle de seguridad —
`formatear_default/2` valida antes de escribir código Elixir fuente a
disco — en `catalogo-maestro-detalle-requerimientos.md` R13, no se
repite acá).

## 4. Estados (R10-R13)

### 4.1 Gate de habilitación

`@puede_agregar` para `tabla_estados/1` = `@campos != []` — sin
ningún campo de negocio, "+ Agregar estado" queda deshabilitado
(R10). No hay gate sobre CUÁNTOS estados puede tener un catálogo.

### 4.2 Estado inicial forzado (R11-R12)

`MetaEstadosAdmin.crear_estado/1` → `forzar_inicial_si_es_el_primero/1`:
si `meta_schema_estados` todavía no tiene NINGUNA fila viva para ese
`meta_schema_header_id` (`tiene_algun_estado?/1`), fuerza
`es_inicial: true` en los `attrs` ANTES de insertar — el formulario
(`modal_estado/1`) refleja esto mostrando el aviso fijo en vez del
checkbox cuando `@form["es_inicial_forzado"]` es true (calculado en
el `handle_event("abrir_form_estado", ...)` en base a si ya existe
algún estado). El invariante real "a lo sumo un inicial" lo garantiza
la base (`meta_schema_estados_un_inicial_index`, índice único parcial
`WHERE es_inicial = true AND delete_guid IS NULL` — ver nota de
mantenimiento en §6), el formulario solo evita que el usuario intente
violarlo desde acá.

### 4.3 Eliminar estado (R13)

Un estado es eliminable (soft-delete, `delete_guid`) únicamente si NO
aparece como `estado_origen_id` ni `estado_destino_id` de ninguna
transición viva (`referenciados` calculado con `MapSet` sobre
`@transiciones` en `tabla_estados/1`) — si está referenciado, el
botón "Eliminar" directamente no se renderiza (no es un botón
deshabilitado con tooltip, desaparece).

## 5. Transiciones (R14-R21)

### 5.1 Gate de habilitación (R14)

`@puede_agregar` para `tabla_transiciones/1` = `@estados` tiene al
menos un `es_inicial: true`. Sin eso, "+ Agregar transición" queda
deshabilitado — coherente con que toda transición necesita un
Destino válido entre los estados existentes.

### 5.2 Self-loop y `campos_editables` (R16-R17)

Una transición es self-loop cuando `estado_origen_id ==
estado_destino_id` (ambos no-nil). El aviso ámbar de la tabla
(R16) es puramente informativo — no bloquea guardar una self-loop
sin `campos_editables`, solo advierte que cualquier intento real de
usarla para editar (`PATCH`, o el flujo de edición de
`FichaLive`/`CatalogoLive`) va a fallar en el motor
(`MetaStateEngine`, fuera de esta spec) por whitelist vacía.

La acción reservada `"guardar"` como self-loop es la que
`MetaStateEngine.transicion_guardar/2` busca por convención de nombre
(`accion == "guardar" and estado_origen_id == estado_destino_id ==
<estado actual>`) para resolver qué transición ejecuta un `PATCH`
directo — no hay ninguna marca "es la transición de guardar" en el
schema, es 100% por el string `"guardar"` + self-loop en el estado
actual del registro.

### 5.3 Campos editables por tabs (R19)

`modal_transicion/1` arma un tab por "Encabezado" + uno por cada
`@catalogos_detalle` (`MetaSchemaContext.listar_catalogos_detalle/1`
del maestro). Los inputs `campos_editables[]` de TODOS los tabs
existen simultáneamente en el DOM (los ocultos solo con
`display:none`, nunca desmontados) para que el único `<form
phx-submit="guardar_transicion">` que envuelve todo el modal junte la
selección real sin importar en qué tab quedó el usuario al enviar —
`.grupo_campos_editables/1` (buscador + "Todos/Ninguno" por grupo) es
el mismo componente para header y cada detalle.

### 5.4 Permisos por transición (R20-R21)

`permisos_transicion/3`:

```elixir
defp permisos_transicion(header, catalogos_detalle, accion) do
  recursos = [{header.schema_context_name, header.schema_context_label}
              | Enum.map(catalogos_detalle, &{&1.nombre, &1.etiqueta})]

  Enum.map(recursos, fn {recurso, etiqueta} ->
    %{recurso: recurso, etiqueta: etiqueta, existe: Permissions.permiso_existe?(recurso, accion)}
  end)
end
```

Se recalcula al abrir `abrir_editar_transicion` (nunca al crear una
transición nueva — sin `accion` definitiva todavía no hay
`{recurso, accion}` que verificar). `handle_event("registrar_permiso_transicion",
%{"recurso" => recurso}, socket)` llama
`Permissions.crear_permiso/1` con la `accion` actual del formulario en
memoria (no la persistida — si el usuario cambió el texto de Acción
sin guardar todavía, registra el permiso para el nombre nuevo) y
marca esa fila como `existe: true` en el assign, sin recargar del
todo el formulario. Un `{:error, _}` de `crear_permiso/1` (típicamente
unique constraint, ya existía) se trata igual que éxito — el objetivo
es que la fila EXISTA, no evitar duplicados visualmente.

Esto crea el registro base en `meta_schema_permiso`
(`{recurso, accion}`) que hace ELEGIBLE a un rol para recibirlo —
CONCEDER el permiso a un rol puntual sigue siendo responsabilidad de
Roles/Permission Sets (`RolesLive`/`CatalogoPermisosLive`), fuera de
este tab.

## 6. Indicador de completitud (R22-R23)

`pasos_motor/5` arma la lista `[{etiqueta, completo?}, ...]` que
alimenta el stepper de la cabecera del BC Motor, con dos cláusulas
por `@es_detalle?`:

- **Catálogo normal**: `Campos → Estado inicial → Estados →
  Transiciones → Reglas` + opcionales.
- **Catálogo detalle**: `Campos → Reglas` + opcionales — Estado
  inicial/Estados/Transiciones NUNCA aparecen (mismo criterio que
  oculta esos tabs por completo, R14 de requirements).

Los pasos "booleanos" se derivan de `MetaEstadosAdmin.completitud/1`
(consulta única contra estados/transiciones/reglas del header) —
`tiene_alta_o_inicial?` es cierto si hay un estado `es_inicial` O una
transición de alta sin origen (dos formas históricas distintas de
"cómo entra un registro nuevo al autómata", ambas válidas).
`pasos_opcionales/2` decide Permisos/Relaciones/Get Config/Post
Config con la misma regla: aparecen solo cuando hay algo YA
configurado o algo REALMENTE pendiente (ej. una referencia sin
`campos_acompanamiento`) — nunca como paso vacío permanente.

## 7. Notas de mantenimiento (hallazgos de sesiones reales)

- `meta_schema_estados_un_inicial_index` originalmente no filtraba
  `delete_guid IS NULL` — un estado inicial borrado lógicamente
  seguía bloqueando crear uno nuevo con "ya existe un estado inicial
  para este catálogo", mientras la tabla de Estados (que sí filtra
  borrados) mostraba "todavía no tiene estados" — inconsistencia real
  corregida vía migración (`20260910193000_filtrar_borrados_en_indice_estado_inicial.exs`),
  mismo criterio aplicado también al índice de nombre único de
  estado.
- `CatalogoGenerico.crear/2` (fuera de este tab, pero gateado por lo
  que acá se configura) rechaza el alta de un catálogo BC de negocio
  (no-detalle) que no tiene NINGÚN estado — antes cualquier catálogo
  sin autómata caía en silencio al modo "simple" sin `estado_id`
  (2026-09-10, hallazgo real con un catálogo de Fabricante que
  aceptaba datos sin un solo estado definido). El gate real es
  `MetaStateEngine.estado_inicial/1`, no la existencia de una
  transición "alta" formal — un catálogo con un estado `es_inicial`
  pero sin transición "alta" todavía sigue pudiendo recibir altas
  (`crear_simple/4` asigna el estado inicial igual), config
  intermedia válida mientras se termina de armar el autómata.
