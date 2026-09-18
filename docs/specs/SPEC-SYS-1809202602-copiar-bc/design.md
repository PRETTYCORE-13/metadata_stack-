# SPEC-SYS-1809202602 — Copiar un BC desde BC List

**Documento:** Design · **Fase:** ✅ aprobada (2026-09-18).

## 1. Por qué casi no hace falta código nuevo de bajo nivel

Crear un catálogo YA tiene un camino robusto y probado
(`BcNuevoCompletoLive` → `MetaEstadosAdmin.crear_proceso_completo/1`
→ `CatalogoGenerador.generar/1`, que a su vez crea la migración, el
módulo Ecto, la corre, y llama a
`MetaPlantillas.crear_plantilla_default/1`). "Copiar" **reusa ese
mismo camino tal cual** — lo único genuinamente nuevo es la función
que arma los `attrs` de entrada (header + detalles + estados +
transiciones) A PARTIR de un catálogo existente, con los prefijos de
campo renombrados. Confirmado en vivo (2026-09-18, clon manual de
`pty_dsd_cs_vigencias_frec`): el mismo `crear_proceso_completo/1` +
`generar/1` de siempre, alimentados con attrs ya renombrados, arman
header+detalles+estados+transiciones+tabla+migración+plantilla
automática sin ningún ajuste especial.

## 2. Módulo nuevo: `MetadataApp.MetaClonador`

Mismo criterio que `MetaPublicador`/`MetaTepache`: un módulo de
ORQUESTACIÓN aparte para un flujo que cruza `MetaSchemaContext`
(leer header/detalles) + `MetaEstadosAdmin` (leer/crear
estados/transiciones) + `CatalogoGenerador` (generar físico), en vez
de mezclarlo dentro de cualquiera de esos tres.

```elixir
@doc """
{:ok, header_nuevo} | {:error, mensaje}
`atributos_nuevos`: %{"schema_context_name", "schema_context_label",
"schema_context_nav", "schema_context_icono"} — lo que el admin tipeó
en el modal (R2/R3 de requirements.md).
"""
def clonar(nombre_original, atributos_nuevos)
```

Pasos internos de `clonar/2`:

1. **Validar origen**: `MetaSchemaContext.obtener_header_por_nombre/1`
   existe, `schema_context_type == 1`, `schema_encabezado_id == nil`,
   y `MetaSchemaContext.listar_catalogos_detalle(header.id) == []`
   (sin detalles propios) — si no cumple, `{:error, "..."}` antes de
   tocar nada (alcance v1, requirements.md §1).
2. **Validar destino** — reusa EXACTO el criterio de
   `BcNuevoCompletoLive.validar_contexto/3` (regex de nombre/nav +
   `validar_nav_libre/1`) — mismo mensaje de error, misma UX que
   "Nuevo catálogo".
3. **Armar `attrs_base`** con `renombrar_para_clon/3` (§3) sobre
   detalles + estados + transiciones del original.
4. **Crear** con `MetaEstadosAdmin.crear_proceso_completo/1` (mismo
   que usa `BcNuevoCompletoLive`) — todo o nada, transaccional.
5. **Generar físico**: `CatalogoGenerador.generar(nombre_nuevo)` —
   migración + módulo Ecto + corre la migración + plantilla
   automática (R11/R12). Si falla ACÁ (después de 4), el header ya
   quedó creado — mismo riesgo que ya acepta hoy
   `BcNuevoCompletoLive.handle_event("crear", ...)` con
   `activar_alcance_con_default_sucursal/1` (no hay rollback
   automático de metadata si la generación física falla; el admin ve
   el error y puede reintentar "Generar" desde BC Motor, que ya
   reintenta `generar/1` de forma idempotente si la tabla no existe
   todavía).
6. Devuelve `{:ok, header_nuevo}`.

**Deliberadamente NO llama** a
`activar_alcance_con_default_sucursal/1` aunque el original tenga
`alcance_habilitado: true` — ese helper además fuerza `alcance_tipo:
"branch"` en TODOS los roles (pensado para "nace de cero"), que
pisaría configuración real de rol si algún admin ya la tocó desde
que arrancó la app. `clonar/2` en cambio pasa `alcance_habilitado`
como un atributo más del header (R4) — si el original lo tenía
activado, `crear_proceso_completo/1` ya lo persiste así, y
`generar/1` construye las columnas de alcance correctas porque lee el
header YA actualizado de la base (mismo orden causal que
`provisionar_alcance/1` ya usa: header primero, generar después).

## 3. Algoritmo de renombrado — `renombrar_para_clon/3`

```elixir
@doc "atributos_nuevos ya validados. {header_attrs, estados_attrs, transiciones_attrs} listos para crear_proceso_completo/1."
defp renombrar_para_clon(header_original, atributos_nuevos, nombre_original)
```

**Regla única, aplicada en dos lugares:**

```elixir
defp renombrar_campo(campo, nombre_original, nombre_nuevo) do
  prefijo = nombre_original <> "_"
  if String.starts_with?(campo, prefijo) do
    nombre_nuevo <> "_" <> String.trim_leading(campo, prefijo)
  else
    campo
  end
end
```

- **Detalles** (`MetaSchemaContext.listar_detalles/1` del original,
  EXCLUYENDO `"fecha_registro"` — nunca se clona, `generar/1` la
  vuelve a agregar sola, R8 de la spec de Get Config ya documentado
  en otro lado no aplica acá, es una regla distinta: control field
  siempre automático):
  - `schema_context_field`: `renombrar_campo/3`.
  - `schema_context_properties["campos_relacion"]` (si existe): cada
    string de la lista pasa por `renombrar_campo/3` — es SIEMPRE una
    autoreferencia al propio catálogo (R6).
  - Todo lo demás de `schema_context_properties` (`tipo`, `etiqueta`,
    `orden`, `visible`, `editable`, `opcional`, `catalogo`,
    `campo_visualizacion`, `campos_acompanamiento`, `longitud`,
    `precision`, `escala`, `es_parametro`, `defaults`, `acotado`,
    ...) se copia **tal cual, sin tocar** — `catalogo`/
    `campo_visualizacion`/`campos_acompanamiento` son del catálogo
    REFERENCIADO (R7), nunca del propio.
- **Estados**: se copian tal cual (`nombre`, `orden`, `es_inicial`,
  `color`, `icono`) — un nombre de estado no es un campo, nada que
  renombrar.
- **Transiciones**: `accion`/`etiqueta`/`estado_origen`/
  `estado_destino` tal cual (son NOMBRES de estado, ya copiados
  arriba con el mismo nombre). `campos_editables`: cada entrada pasa
  por `renombrar_campo/3` y LUEGO se filtra contra el set de nombres
  de los detalles YA renombrados — cualquier entrada que no matchee
  ningún campo real del clon se DESCARTA (R9). Caso defensivo, no uno
  real observado en `pty_dsd_cs_vigencias_frec` (esa referencia
  original a `_operacion` resultó estar completa en su metadata — una
  nota anterior de esta spec lo daba como huérfano por error, ver
  corrección en `requirements.md` R8): un `campos_editables` con una
  referencia a un campo que ya no existe SIGUE siendo una situación
  real posible (metadata desincronizada, campo borrado después de
  configurar la transición), solo que no es la que motivó este caso —
  cubierto igual en `meta_clonador_test.exs` reproduciéndolo a mano
  (soft-delete de un detalle después de crear la transición).

```elixir
nombres_nuevos = MapSet.new(detalles_nuevos, & &1["schema_context_field"])

campos_editables_nuevos =
  original
  |> Enum.map(&renombrar_campo(&1, nombre_original, nombre_nuevo))
  |> Enum.filter(&MapSet.member?(nombres_nuevos, &1))
```

Si el original no adoptó el motor de estados
(`MetaEstadosAdmin.listar_estados(header.id) == []`), `estados_attrs`
y `transiciones_attrs` quedan `[]` — `crear_proceso_completo/1` ya
tolera eso para un maestro (no exige autómata si hay al menos un
campo, ver `validar_completo/3`).

## 4. UI — `BcListLive`

Mismo patrón visual/interacción que "Nueva carpeta"/"Editar carpeta"
(modal embebido en el propio `BcListLive`, no una ruta/LiveView
aparte) — reusa el mismo picker de carpeta padre que
`BcNuevoCompletoLive` para la ruta de navegación.

- **Botón "Copiar"** en la celda de acciones (`filas_arbol/1`, junto
  a "Editar"/"Eliminar"), visible solo si:
  `not es_consulta? and is_nil(schema_encabezado_id) and
  listar_catalogos_detalle(header_id) == []` — mismo espíritu que ya
  usa esa celda para ocultar "Eliminar" en Consultas.
- **`phx-click="abrir_copiar"` `phx-value-tabla={nodo.id}`** → carga
  el header original, pre-carga el form con
  `schema_context_label` (+ " (copia)", editable),
  `schema_context_name` vacío (el admin SIEMPRE tipea uno nuevo,
  nunca autogenerado — a diferencia de la etiqueta, un nombre técnico
  copiado a ciegas invitaría a no cambiarlo y chocar), misma carpeta
  padre que el original (derivada de `schema_context_nav`, editable
  con el mismo picker), mismo ícono.
- **`phx-submit="confirmar_copiar"`** → valida (mismo mensaje in-line
  que "Nuevo catálogo" si falla) → `MetaClonador.clonar/2` →
  éxito: cierra modal, `put_flash(:info, ...)`,
  `push_navigate(to: ~p"/sysadmin/bc-list/#{header_nuevo.schema_context_name}/motor")`
  (mismo destino que "Crear catálogo" — el admin cae directo a BC
  Motor del clon para revisar/ajustar antes de publicarlo).
- Error de `MetaClonador.clonar/2` → mensaje in-line en el modal, no
  se cierra (mismo patrón que "Editar carpeta").

## 5. Fuera de alcance (heredado de requirements.md §7)

Sin cambios de diseño — Consultas, detalle standalone,
maestro-detalle completo, plantillas custom, y publicación quedan
fuera de v1.
