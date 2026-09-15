# Design — Resumen de selección

## Resumen del enfoque

`CatalogoLive` ya renderiza catálogos y Consultas con **dos templates
separados** (`render/1` con 3 clausulas: `encontrado?: false`,
`es_consulta?: true` y el catálogo normal) que comparten el motor de
agregación (`CatalogoGenerico.agregar/7` / `MetaConsultas.agregar/6`,
ambos ya soportan `:sum|:avg|:min|:max|:count`) y el formateo de celdas
(`formatear_celda/2`, `formatear_agregacion/2`). Esta spec agrega:

1. Un estado de selección nuevo (`@seleccionados`, un `MapSet` de ids) —
   no existe hoy.
2. Dos funciones de agregación nuevas, acotadas por lista de ids en vez
   de por filtros — reusan el mismo dispatch de función que ya existe,
   nunca reinventan el cálculo.
3. Config nueva por campo (participa del resumen + qué operación +
   etiqueta + formato), agregada al MISMO lugar donde ya vive
   `total_general_activo`/`agregacion_activa`, con el MISMO patrón de
   componente compartido (`celda_totales/1`) que ya extienden
   `bc_motor_live.ex` y `consulta_editor_live.ex`.
4. Una columna de casillero nueva y una barra compacta nueva — en AMBOS
   templates (catálogo y Consulta), agregadas COMO columnas/elementos
   extra por fuera de `@columnas_render`/`@columnas` (mismo criterio ya
   usado para la columna del ícono "Ver ficha 360°", que tampoco es
   parte de esa lista).

Nada de esto toca `total_general_activo`, `agregacion_activa`,
`minmax_recomendado` ni `total_pagina_activo` — son cálculos
independientes que conviven (R10).

## 1. Selección de registros

### Estado

Un solo assign nuevo en `CatalogoLive`: `@seleccionados` (`MapSet` de
`id`, vacío al entrar a la pantalla). Se elige `MapSet` sobre lista por
el mismo motivo que ya lo usa `BcListLive` (`bc_list_live.ex:80`, mismo
patrón): pertenencia O(1), sin duplicados, y `MapSet.size/1` da el
contador gratis.

**Por qué no cachear los VALORES de las filas seleccionadas:** como el
cálculo del resumen (§3) se resuelve con una query nueva por id (no
plegando `@filas` en memoria), alcanza con recordar QUÉ ids están
seleccionados — sin importar si esa fila sigue cargada en pantalla o
quedó en una página ya visitada. Esto resuelve R3 (persiste entre
páginas) sin ningún cache adicional.

### Eventos nuevos

```elixir
def handle_event("toggle_seleccion_fila", %{"id" => id}, socket) do
  id = String.to_integer(id)
  seleccionados = toggle_pertenencia(socket.assigns.seleccionados, id)
  {:noreply, socket |> assign(:seleccionados, seleccionados) |> recalcular_resumen_seleccion()}
end

def handle_event("toggle_seleccion_pagina", _params, socket) do
  ids_pagina = Enum.map(socket.assigns.filas, & &1.id)
  todos_seleccionados? = Enum.all?(ids_pagina, &MapSet.member?(socket.assigns.seleccionados, &1))

  seleccionados =
    if todos_seleccionados?,
      do: Enum.reduce(ids_pagina, socket.assigns.seleccionados, &MapSet.delete(&2, &1)),
      else: Enum.reduce(ids_pagina, socket.assigns.seleccionados, &MapSet.put(&2, &1))

  {:noreply, socket |> assign(:seleccionados, seleccionados) |> recalcular_resumen_seleccion()}
end

def handle_event("limpiar_seleccion", _params, socket) do
  {:noreply, socket |> assign(:seleccionados, MapSet.new()) |> assign(:resumen_seleccion_valores, %{})}
end
```

`toggle_seleccion_pagina` refleja "seleccionar todos los visibles"
(R2) como un toggle único (mismo criterio que un checkbox de
"seleccionar todo" de encabezado en cualquier tabla): si ya está todo
seleccionado, lo deselecciona; si no, completa lo que falte — sin tocar
selecciones de otras páginas.

### R5 — limpiar al cambiar filtros/búsqueda/orden

Los handlers que YA existen y cambian qué datos se están mirando
(`aplicar_filtro`, `quitar_filtro`, `buscar_general`,
`ordenar_por_columna`, cambios de parámetro, cambio de plantilla de
Consulta) agregan `|> assign(:seleccionados, MapSet.new())` a su
`{:noreply, socket}` de salida. Los handlers de **paginación**
(`ir_a_pagina`/equivalente) NO se tocan — ahí es donde R3 exige que la
selección persista.

## 2. Config nueva por campo — modelo de datos

Mismo lugar que ya usa `total_general_activo`/`agregacion_activa`:

- Catálogo: `meta_schema_detail.schema_context_properties` (una fila
  por campo).
- Consulta: un elemento de `Consulta.campos` (jsonb array, namespaced
  por `catalogo__campo`).

Claves nuevas (incluidas en `@claves_totales_consulta`,
`catalogo_live.ex:420`, para que el mecanismo de "traer/guardar estas
propiedades juntas" ya existente las cubra sin tocarlo aparte):

```jsonc
{
  "resumen_seleccion_activo": true,
  "resumen_seleccion_funcion": "suma",       // "suma"|"promedio"|"minimo"|"maximo"|"conteo"
  "resumen_seleccion_etiqueta": "Total",     // por defecto, la etiqueta del campo

  // Formato -- nuevo, independiente de resumen_seleccion_activo: un
  // campo puede tener este formato para SU celda/Total general Y para
  // el Resumen de selección al mismo tiempo (mismo valor formateado en
  // los dos lugares, R16).
  "formato_unidad": "cajas",                 // string libre, "" = sin unidad
  "formato_porcentaje": true                 // boolean
}
```

`mascara_separador`/`mascara_simbolo` (ya existentes) NO se duplican —
siguen siendo la fuente para "separador de miles" y "símbolo de
moneda" tal cual están hoy; `formato_unidad`/`formato_porcentaje` son
las dos únicas piezas realmente nuevas (R16.2/R16.3), porque hoy no
existe ninguna.

### UI de configuración — extender `celda_totales/1`

`parametros_catalogo_components.ex` (`celda_totales/1`, líneas
340-411) ya es el punto de extensión compartido entre `bc_motor_live.ex`
y `consulta_editor_live.ex` (mismo contrato de eventos en los dos,
documentado en el moduledoc del archivo). Se agrega un chip hermano de
`Tot`/`Mín/Máx`/`Pág`/`Gral`:

- **`Sel`** → `phx-click="cambiar_resumen_seleccion_activo"` — togglea
  `resumen_seleccion_activo`.
- Cuando `Sel` está activo, un mini-form nuevo (mismo estilo que el de
  máscara ya existente) con:
  - un `<select>` de función (Suma/Promedio/Mínimo/Máximo/Conteo) →
    `cambiar_resumen_seleccion_funcion`.
  - un `<input>` de etiqueta → `cambiar_resumen_seleccion_etiqueta`.
- El mini-form de máscara YA existente (separador/símbolo) cambia su
  condición de aparición de `agregacion_activa` a
  `agregacion_activa or resumen_seleccion_activo` — un campo puede
  querer símbolo "$" en el Resumen de selección sin necesariamente
  sumar en el Total general.
- Ese mismo mini-form suma dos campos: un `<input>` de unidad
  (`cambiar_formato_unidad`) y un checkbox de porcentaje
  (`cambiar_formato_porcentaje`).

`bc_motor_live.ex` y `consulta_editor_live.ex` implementan los 5
`handle_event` nuevos de forma paralela a como ya implementan
`cambiar_total_general`/`cambiar_agregacion_activa` (persistencia vía
`MetaSchemaContext.actualizar_detalle/2` en el catálogo,
mutación-del-array-y-guardado-completo en la Consulta) — ningún
mecanismo de persistencia nuevo, solo más claves dentro del mismo
`schema_context_properties`/elemento de `campos`.

## 3. Cálculo — nuevas funciones de agregación acotadas por selección

**Nunca reusan `filtros`/`busqueda`/`parametros` de la vista** (R10) —
solo alcance de datos + `id IN (seleccionados)`.

### Catálogo — `CatalogoGenerico.agregar_seleccionados/4`

```elixir
def agregar_seleccionados(_schema_mod, _scope, _campo, _funcion, []), do: nil

def agregar_seleccionados(schema_mod, scope, campo, funcion, ids) do
  campo_atom = String.to_existing_atom(to_string(campo))

  from(r in schema_mod, as: :t0, where: is_nil(r.delete_guid) and r.id in ^ids)
  |> aplicar_alcance_de_datos(scope, schema_mod)
  |> Repo.aggregate(funcion, campo_atom)
end
```

Función nueva, NO una sobrecarga de `agregar/7` — evita forzar `id` a
existir como filtro genérico (`aplicar_filtro/3` no tiene hoy una
cláusula `{:in, lista}}`; no hace falta agregarla, esta función arma
su propio `where` directo).

### Consulta — `MetaConsultas.agregar_seleccionados/5`

Mismo criterio, reusando `construir_query_base/1` y
`aplicar_funcion_agregada/2` (`meta_consultas.ex:1018-1022`, ya
soporta los 5 átomos) tal cual existen. **Corrección durante
implementación (2026-09-09):** a diferencia de lo que decía esta
sección antes, el alcance de datos de una Consulta NO viene aplicado
automáticamente por `construir_query_base/1` — es un paso aparte
(`aplicar_alcance_de_datos/4`, privado, `meta_consultas.ex:627-650`)
que `ejecutar/6`/`agregar/6` sí invocan explícitamente. Omitirlo acá
habría sido una fuga real de alcance (un usuario acotado vería la
agregación de registros fuera de su alcance). La función necesita
`scope` como parámetro:

```elixir
def agregar_seleccionados(_consulta, _scope, _campo_clave, _funcion, []), do: nil

def agregar_seleccionados(%Consulta{} = consulta, scope, campo_clave, funcion, ids) do
  case Enum.find(consulta.campos, &(to_string(clave_campo(&1)) == campo_clave)) do
    nil ->
      nil

    campo ->
      {base, alias_por_catalogo} = construir_query_base(consulta)
      alias_tabla = Map.fetch!(alias_por_catalogo, campo["catalogo"])
      alias_base = Map.fetch!(alias_por_catalogo, consulta.catalogo_base)
      campo_atom = String.to_existing_atom(campo["campo"])
      expr = dynamic([{^alias_tabla, t}], field(t, ^campo_atom))

      base
      |> where([{^alias_base, t}], t.id in ^ids)
      |> aplicar_alcance_de_datos(consulta, alias_por_catalogo, scope)
      |> exclude(:order_by)
      |> select(^aplicar_funcion_agregada(funcion, expr))
      |> Repo.one()
  end
end
```

### `CatalogoLive.recalcular_resumen_seleccion/1`

Mismo patrón que `recalcular_agregaciones/1` (una query por campo
configurado, `catalogo_live.ex:901-909`): recorre los campos con
`resumen_seleccion_activo == true` de `@columnas`/`@columnas_render`
según corresponda, llama a `agregar_seleccionados/4` (o `nil` sin
selección) y guarda el resultado en un assign nuevo
`@resumen_seleccion_valores` (`%{clave => valor}`). Se invoca al final
de los 3 handlers de §1 y NUNCA desde los handlers de filtro/búsqueda/
orden (ahí la selección ya se vació, así que el resumen directamente
se limpia a `%{}` sin consultar nada).

## 4. Formato de los indicadores

`formatear_agregacion/2` (`catalogo_live.ex:2026-2042`) se extiende con
los dos casos nuevos, evaluados ANTES que el separador/símbolo actual
(un valor no pasa por los dos formatos a la vez salvo separador de
miles, que aplica siempre sobre el número):

```elixir
defp formatear_indicador_resumen(valor, props) do
  numero = separar_miles(valor, props["mascara_separador"])

  cond do
    props["formato_porcentaje"] -> "#{numero}%"
    props["formato_unidad"] not in [nil, ""] -> "#{numero} #{props["formato_unidad"]}"
    true -> aplicar_simbolo(numero, props["mascara_simbolo"])
  end
end
```

Reusa `separar_miles/2`/`aplicar_simbolo/2` tal cual existen — solo
agrega los dos casos nuevos (unidad, porcentaje) que hoy no existen en
ningún lado de la plataforma (R16.2/R16.3).

## 5. Renderizado

### Columna de casillero (ambos templates)

Igual que la columna del ícono "Ver ficha 360°" (ya vive FUERA del
`for columna <- @columnas_render`/`@columnas`, `catalogo_live.ex:1508/
1517-1525`), se agrega una columna de casillero simétrica, esta vez
como PRIMERA columna:

- `<thead>`: un `<th>` con un checkbox atado a `toggle_seleccion_pagina`
  (marcado si `todos_seleccionados_en_pagina?/2` da `true`).
- `<tbody>`: un `<td>` con un checkbox por fila, atado a
  `toggle_seleccion_fila` con `phx-value-id={fila.id}`, marcado si
  `MapSet.member?(@seleccionados, fila.id)`.
- `<tfoot>`: una celda vacía extra, para mantener alineadas las
  columnas de Totales (mismo `<td></td>` que ya usa la columna del
  ícono, `catalogo_live.ex:1551`).

Se hace en LOS DOS templates (`render/1` con `es_consulta?: true` y el
default) — comparten el mismo shape de evento/assign, cambia solo
dónde se inserta la celda dentro de cada tabla.

### Barra de Resumen de selección

Un componente nuevo, `resumen_seleccion/1`, insertado en la banda de
acciones superior (mismo lugar que el botón "Descargar Excel" agregado
en esta sesión, `catalogo_live.ex:~1432-1439`) en ambos templates:

```heex
<.resumen_seleccion
  :if={MapSet.size(@seleccionados) > 0}
  cantidad={MapSet.size(@seleccionados)}
  indicadores={@resumen_seleccion_valores}
/>
```

- Un pill/chip con fondo e ícono propios (ej. tono ámbar o violeta
  distinto del gris de los botones de acción — R18), formato compacto
  en una sola línea: `"{cantidad} seleccionados · {etiqueta} {valor} ·
  ..."` (R17), con un botón chico "Limpiar" (`limpiar_seleccion`, R4).
- `:if` en la cantidad cubre R7/R8 (aparece/desaparece) sin lógica
  aparte.

## 6. Fuera de alcance (explícito)

- Cualquier acción masiva sobre la selección (imprimir, marcar como,
  capturar pagos, exportar solo lo seleccionado) — R6. Esta spec deja
  el `MapSet` de ids como única superficie reusable para una spec
  futura.
- Cambios a `total_general_activo`, `agregacion_activa`,
  `minmax_recomendado`, `total_pagina_activo` o a las funciones que ya
  los calculan — se leen, nunca se modifican (R10, R15 de
  requirements.md).
- Seleccionar "todos los N registros que matchean el filtro" más allá
  de la página actual (patrón tipo Gmail) — R2 se limita a la página
  visible.
- Persistir la selección más allá de la sesión del socket (recargar la
  página, o abrir la misma pantalla en otra pestaña, empieza sin
  selección) — no lo pidió el requerimiento.
