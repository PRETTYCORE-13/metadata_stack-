# SPEC-SYS-1109202603 — BC Motor: Tab Contrato

**Documento:** Design · **Fase:** ✅ aprobada (2026-09-11).

Documentación retroactiva — describe el mecanismo tal como existe en
`lib/metadata_app_web/live/sysadmin/bc_motor_live.ex`
(`panel_api/1` y sus funciones auxiliares, `bc_motor_live.ex:3228-3501`).
Todo el tab es DERIVADO: no hay ninguna fila de base de datos "doc de
API" — cada render recalcula el contrato completo a partir de
`@campos`, `@estados`, `@transiciones` y los catálogos detalle del
header, así que nunca puede quedar desactualizado respecto a la
configuración real (a diferencia de una documentación escrita a
mano).

## 1. Visibilidad del tab (R1, R5)

Mismo patrón que el tab Diagrama (`SPEC-SYS-1109202602`): la entrada
`%{key: "api", label: "Contrato"}` vive dentro del bloque
`unless(@es_detalle?, do: [...])` de la barra de tabs
(`bc_motor_live.ex:2036-2043`) — un catálogo detalle no tiene esa
pestaña. Su documentación no desaparece: `panel_api/1` del MAESTRO
arma `catalogos_detalle` (`MetaSchemaContext.listar_catalogos_detalle/1`
+ `listar_detalles/1` de cada uno) y documenta sus endpoints de
renglones ahí mismo (R4/R5, ver §3).

## 2. Datos fuente y ejemplos (R13-R15)

### 2.1 Valor de ejemplo por campo

`valor_ejemplo_campo/1` (`bc_motor_live.ex:1904-1917`) — un `case` por
`propiedades["tipo"]`, sin acceso a datos reales de la tabla (los
ejemplos son 100% sintéticos, deterministas, no dependen de que el
catálogo tenga filas):

```elixir
defp valor_ejemplo_campo(propiedades) do
  case Map.get(propiedades, "tipo", "string") do
    "string" -> "texto"
    "integer" -> 1
    "decimal" -> 10.5
    "boolean" -> true
    "date" -> "2026-01-15"
    "hora" -> "14:30"
    "texto_largo" -> "texto largo…"
    "enum" -> (propiedades |> Map.get("valores", ["valor_a"]) |> List.first()) || "valor_a"
    "referencia" -> 1
    _ -> "texto"
  end
end
```

### 2.2 Composición de un registro/payload de ejemplo

- `ejemplo_payload/1` — mapa `%{campo => valor_ejemplo}` para TODOS
  los campos de negocio de una lista de campos dada (header o un
  detalle) — nunca incluye `id`/`estado_id` (esos están fuera de
  `@campos` por diseño del generador, ver `MetaCatalogoGenerico.__using__/1`).
- `ejemplo_registro/2` (R14) — `ejemplo_payload/1` + `"id" => 1` +,
  si el catálogo adoptó el motor de estados, `estado_id`/`estado_nombre`
  del estado inicial (o el primero de la lista si ninguno está
  marcado inicial — caso de configuración incompleta, no debería
  pasar en un catálogo real pero no explota si pasa).
- `ejemplo_payload_con_renglones/2` (R6) — `ejemplo_payload/1` del
  header + `"renglones" => %{"<detalle>" => [dos ejemplos, ...]}`
  por cada catálogo detalle; con `catalogos_detalle == []` es
  exactamente `ejemplo_payload/1`, sin la llave (retrocompatible con
  cualquier catálogo sin detalles).

### 2.3 Orden de las llaves (R15)

`json_pretty/1` → `id_primero/1` (`bc_motor_live.ex:1963-1971`):
recorre el mapa (y listas de mapas, recursivo) separando la entrada
`"id"` del resto y arma un `Jason.OrderedObject` con `id` primero —
`Jason.encode!/2` sobre un `Map` de Elixir NO garantiza ningún orden
de llaves (confirmado a mano, no es alfabético ni de inserción), así
que sin este paso el ejemplo mostraría `id` en cualquier posición
entre corrida y corrida.

## 3. Endpoints de lectura (R2-R5)

`panel_api/1` arma `meta_campos`/`meta_campos_detalle` (mismo shape
que realmente devuelve `GET /api/:tabla`, ver
`catalogo-maestro-detalle-requerimientos.md` R10) y los mete en
`respuesta_lista_mapa`/`respuesta_uno_mapa` vía
`agregar_si_no_vacio/3` — `meta_campos_detalle` solo aparece en el
JSON de ejemplo si el mapa no es `%{}` (R3), nunca como llave vacía.

`renglones_detalle_doc` (R4) arma, por cada catálogo detalle, una
tarjeta `GET /api/:detalle?encabezado_id=:id` con `meta_campos`
propio del detalle y un renglón de ejemplo (`ejemplo_payload/1` +
`id`/`encabezado_id`/`renglon_id`/`estado_id`/`estado_nombre` fijos)
— el comentario en el código aclara que esto documenta, de paso, que
el filtro por query string acepta CUALQUIER campo real (no solo
`encabezado_id`), respondiendo una pregunta real de un usuario.

## 4. Endpoints de alta (R6-R8)

`payload_crear` = `ejemplo_payload_con_renglones/2` — cuerpo de
`POST /api/:tabla`. `payload_crear_lote` es un ejemplo DELIBERADAMENTE
distinto (`%{tabla => [ejemplo_payload(campos), ejemplo_payload(campos)]}`,
sin `"renglones"` por item) — el comentario en el código es explícito
sobre por qué: mezclar "cuántos registros manda el lote" con "cuántos
renglones tiene un registro" en el mismo ejemplo generaba confusión
real, aunque el body real SÍ admite ambos combinados si hace falta
(el texto de la tarjeta lo aclara sin mostrarlo).

El aviso de transición de alta (R8) se arma separando
`assigns.transiciones` con `Enum.split_with(&is_nil(&1.estado_origen_id))`
— `transiciones_alta` nunca se documenta como
`POST /:id/transiciones/<accion>` porque `resolver_transicion/3` de
`MetaStateEngine` busca la transición por el `estado_id` ACTUAL de un
registro que ya existe, y un registro recién creado nunca tiene
`estado_id: nil` — ese endpoint, si se documentara, describiría un
request que siempre falla.

## 5. Endpoints de transición (R9-R12)

`transiciones_doc` = `Enum.map(transiciones_normales, &ejemplo_transicion/6)`.
`ejemplo_transicion/6` (`bc_motor_live.ex:3377-3417`):

1. `separar_editables/3` (`bc_motor_live.ex:3424-3439`) — divide la
   lista PLANA `transicion.campos_editables` en `editables_header`
   (los que pertenecen a `@campos` del maestro) y `editables_detalle`
   (mapa `%{catalogo_detalle => [campos]}`) comparando cada nombre
   contra el `MapSet` de nombres reales de cada catálogo — NUNCA por
   prefijo de string (dos campos de catálogos distintos podrían
   compartir prefijo por coincidencia).
2. `payload_header` = valores de ejemplo de los campos editables del
   header. `payload_renglones` = `ejemplo_renglones/2`: un item de
   ejemplo POR catálogo detalle SIEMPRE (aunque esta transición
   puntual no edite ningún campo de ese detalle — mover renglones de
   estado es válido igual, R11), con solo `"renglon_id" => 1` cuando
   no hay campos editables de ese detalle en esta transición.
3. `body_mapa` = `payload_header`, con `"renglones"` agregado SOLO si
   `payload_renglones != %{}` (catálogo sin detalles nunca muestra la
   llave).
4. `descripcion` — 3 variantes según `campos_editables == []` y si el
   catálogo tiene detalles, para que el texto sea preciso en cada
   caso (nunca "no acepta campos" si en verdad SÍ puede mover
   renglones).
5. `registro_tras_transicion` (R12) = `registro` base +
   `estado_id`/`estado_nombre` del DESTINO + `payload_header`
   mergeado — la respuesta de ejemplo siempre es "cómo queda" el
   registro, no un eco del request.

`GET /:id/transiciones` (R9) usa `ejemplo_transiciones_disponibles/1`
— forma genérica (`disponible: true, razones: []` para todas), sin
evaluar precondiciones reales contra ningún registro (no hay un
registro real en este contexto, es documentación estática).

## 6. Presentación (R16-R17)

`tarjeta_endpoint/1` (`bc_motor_live.ex:3475-3501`) — function
component reusado por CADA endpoint de este tab: badge de método con
color fijo por verbo HTTP (`bg-blue-600`/`bg-green-600`/`bg-amber-600`/
`bg-red-600` para GET/POST/PATCH/DELETE respectivamente — DELETE no
se usa hoy en este tab, el estilo ya está preparado si algún endpoint
lo necesita a futuro), URL en `font-mono`, y bloques "Body"/"Respuesta
`<status>`" como `<pre>` con `overflow-x-auto` (JSON largo no rompe
el layout de la tarjeta).

`panel_api/1` termina con
`<p :if={!@tiene_transiciones}>Este catálogo todavía no tiene
transiciones definidas.</p>` (R17) — mismo criterio de "explicar el
vacío" que ya usan las tablas de Estados/Transiciones del tab
Configuración.

## 7. Fuera de alcance

Igual que `requirements.md` §8.
