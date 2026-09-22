# SPEC-SYS-1109202607 — BC Motor: Tab Post Config

**Documento:** Design · **Fase:** ✅ aprobada (2026-09-11).

Documentación retroactiva — `lib/metadata_app_web/live/sysadmin/plantilla_constructor_live.ex`
(módulo completo, ~1700+ líneas; acá solo la parte de ciclo de vida
e integración, ver alcance acotado en `requirements.md`).

## 1. Montaje embebido (R1-R2)

`%{key: "postview", label: "Post Config"}` vive en el bloque
incondicional de tabs (`bc_motor_live.ex:2044-2047`), igual que
Relaciones/Get Config — sin `unless(@es_detalle?, ...)`. El panel:

```elixir
<div id="motor-panel-postview" class="hidden">
  {live_render(@socket, MetadataAppWeb.Sysadmin.PlantillaConstructorLive,
    id: "plantilla-embebido-#{@header.schema_context_name}",
    session: %{"nombre" => @header.schema_context_name}
  )}
</div>
```

`PlantillaConstructorLive.mount/3` tiene 2 cláusulas: una para la
ruta propia (`%{"nombre" => nombre}` en `params`) y otra para este
uso embebido (`session: %{"nombre" => nombre}`, `params` fijo en
`:not_mounted_at_router`) — ambas delegan a `montar/3` con
`embebido?: true|false`, que solo cambia detalles visuales (título
propio + subtítulo vs. nada, `render/1` con `:if={!@embebido?}`).

## 2. Dos propósitos (R3-R4)

`Plantilla.proposito` es `"vista"` (default) o `"impresion"` —
`nueva_plantilla` crea con `%{"proposito" => "vista"}` implícito (no
se pasa, es el default del schema), `nueva_plantilla_impresion` fuerza
`%{"proposito" => "impresion"}` explícito. El `<select>` del header
(`bc_motor_live.ex` no interviene acá, es 100% de
`PlantillaConstructorLive`) agrupa con `<optgroup label="Vistas">`/
`<optgroup label="Impresión">`, filtrando `@plantillas` por
`&1.proposito` — el optgroup de Impresión ni se renderiza si el
catálogo no tiene ninguna (`:if={Enum.any?(@plantillas, &(&1.proposito == "impresion"))}`).

## 3. Estado borrador/publicada (R5-R6)

`recargar_estado/2` es la pieza clave de R6:

```elixir
defp recargar_estado(p, publicada) when p.id == publicada.id, do: publicada
defp recargar_estado(p, _publicada), do: %{p | estado: "borrador"}
```

Llamada dentro de `handle_event("publicar", ...)` sobre TODA
`@plantillas` después de `MetaPlantillas.publicar_plantilla/1` —
degrada cualquier otra en memoria a `"borrador"` en el mismo momento
que persiste la nueva como publicada (la garantía real de "a lo sumo
una publicada por propósito" vive en `MetaPlantillas` del lado
servidor, esto solo mantiene el assign local en sincronía sin una
recarga completa de la lista).

`etiqueta_opcion_plantilla/1` (R5, texto del `<option>`) distingue
"Vista predeterminada" (+ "· disponible" si `disponible_multi_vista`,
R7) para la publicada de propósito "vista" — el texto del botón de
publicar (línea 1116) usa la misma lógica de propósito para no decir
"Vista default" sobre una plantilla de impresión.

## 4. Disponible como vista (R7)

`alternar_disponible_multi_vista` — toggle directo sobre
`Plantilla.disponible_multi_vista` (booleano), independiente del
`estado`. `MetaPlantillas.listar_disponibles_multi_vista/1` (fuera de
esta spec, consumida por `FichaLive` para armar
`@vistas_disponibles`, el `<select>` "Vista: ..." que ve el usuario
final) es la única función que de verdad lee este flag para construir
el selector — acá solo se persiste.

## 5. Guardar/Publicar y conflicto (R8-R10)

```elixir
defp plantilla_desactualizada?(socket) do
  actual = MetaPlantillas.obtener_plantilla!(socket.assigns.plantilla.id)
  actual.update_guid != socket.assigns.plantilla.update_guid
end
```

Optimistic locking real: compara el `update_guid` actual en base
contra el que el socket cargó cuando esta plantilla se seleccionó por
última vez — NO un timestamp (evita problemas de resolución/reloj),
mismo patrón de guid-por-escritura que usa el resto de la app
(`insert_guid`/`update_guid` en cualquier tabla). Tanto "guardar"
como "publicar" (R8) chequean esto ANTES de escribir nada — si hay
conflicto, `@mensaje = {:conflicto, "..."}` con el botón "Recargar"
(R9), nunca un intento de merge automático.

`handle_event("recargar_plantilla", ...)` (R10):

```elixir
def handle_event("recargar_plantilla", _params, socket) do
  header_id = socket.assigns.header.id
  plantilla_fresca = MetaPlantillas.obtener_plantilla!(socket.assigns.plantilla.id)

  {:noreply,
   socket
   |> assign(:plantillas, MetaPlantillas.listar_plantillas(header_id))
   |> assign(:mensaje, nil)
   |> seleccionar(plantilla_fresca)}
end
```

Recarga la LISTA completa (no solo la plantilla en conflicto) — por
si otra plantilla del mismo catálogo también cambió de estado
mientras tanto (ej. alguien más publicó una distinta).

`"publicar"` encadena `actualizar_definicion/2` (guarda) +
`publicar_plantilla/1` (promueve) con un `with` — si guardar falla,
nunca llega a intentar publicar.

## 6. Vista previa y Regenerar automática (R11-R12)

`registro_muestra_id` (calculado en `montar/3`) busca UNA fila
cualquiera del catálogo vía `CatalogoGenerico.listar(modulo, :sistema,
%{}, limit: 1)` — `:sistema` porque esto es una herramienta del
Constructor, no una consulta con alcance de un usuario final; `nil`
si el catálogo no tiene módulo generado o está vacío, y el botón
"Vista previa" ni se muestra en ese caso (no tiene sentido
previsualizar sin ningún dato). El hook `AbrirVistaPrevia`
(`assets/js/app.js`) abre la pestaña `about:blank` de forma SÍNCRONA
en el clic (para que el navegador no la bloquee como pop-up) y recién
le pone la URL real cuando el servidor confirma el guardado — el
comentario en el código aclara que sin este orden, `window.open`
dentro de un `handleEvent` (después del viaje de ida y vuelta al
servidor) llega tarde y el navegador lo bloquea.

`regenerar_automatica` llama `MetaPlantillas.regenerar_plantilla_automatica/1`
(fuera de esta spec) y refresca `@plantillas` — si la plantilla
actualmente seleccionada ES la que se acaba de regenerar,
`seleccionar/2` la recarga en pantalla; si no, la lista se actualiza
mostrando su nuevo contenido, sin tocar la plantilla que el usuario
tiene abierta ahora mismo.

## 7. Fix real — Folio faltaba en la paleta de campos de control (R6a)

`@campos_control` (`plantilla_constructor_live.ex:101-118`, lista
local de este módulo — NO la misma constante que `bc_motor_live.ex`
ni `catalogo_live.ex`, cada LiveView tiene la suya) tenía 8 entradas:
ID/Estado/TRN/Empresa/Sucursal/Almacén/Unidad de venta/Creado por —
sin Folio. El render (`FichaLive.nodo_plantilla_render/1` para tipo
`"campo"`) YA soportaba `"folio"` desde que se construyó la feature
de folio (`@claves_campos_control` en `ficha_live.ex` línea 58 ya lo
incluía, con `valor_legible_control("folio", ...)` propio) — esta
paleta específica del Constructor simplemente quedó afuera al agregar
la feature, un catálogo con folio no podía colocar el nodo al armar
un diseño custom. Agregado como novena entrada (mismo shape que las
demás, `requiere_alcance?: false`), verificado que el render ya lo
resolvía antes de tocar la paleta.

## 8. Fuera de alcance

Igual que `requirements.md` §7.
