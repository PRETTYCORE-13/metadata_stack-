# SPEC-SYS-1109202602 — BC Motor: Tab Diagrama

**Documento:** Design · **Fase:** ✅ aprobada (2026-09-11). Verificación interactiva en navegador pendiente, ver `tasks.md`.

Documentación retroactiva — describe el mecanismo tal como existe en
`lib/metadata_app_web/live/sysadmin/bc_motor_live.ex` (generación de
la definición) + `assets/js/app.js` (hook `DiagramaMotor`, librería
Mermaid vendorizada en `priv/static/vendor/mermaid.min.js`).

## 1. Visibilidad del tab (R1)

La barra de tabs (`bc_motor_live.ex:2031-2053`) arma el tab
`%{key: "diagrama", label: "Diagrama"}` dentro del bloque
`unless(@es_detalle?, do: [...])` — para un catálogo detalle
(`header.schema_encabezado_id != nil`) el tab directamente no existe
en la lista, ni siquiera oculto: es coherente con que Estados/
Transiciones tampoco se editan ahí (ver
`SPEC-SYS-1109202601-bc-motor-tab-configuracion` R14).

## 2. Generación de la definición (R2-R6)

`diagrama_mermaid(estados, transiciones)` (`bc_motor_live.ex:2154-2178`)
corre dentro de `cargar_motor/1` — la función que recarga TODOS los
assigns del LiveView después de cualquier alta/edición/baja sobre el
catálogo, así que `@diagrama` siempre refleja el estado real de la
base en el momento del render, nunca un diff incremental sobre la
versión anterior:

```elixir
defp diagrama_mermaid(estados, transiciones) do
  alias_por_id = estados |> Enum.with_index(1) |> Map.new(fn {e, i} -> {e.id, "e#{i}"} end)

  declaraciones = Enum.map(estados, fn e ->
    ~s(    state "#{e.orden} - #{escapar_mermaid(e.nombre)}" as #{Map.fetch!(alias_por_id, e.id)})
  end)

  iniciales = estados |> Enum.filter(& &1.es_inicial)
              |> Enum.map(&"    [*] --> #{Map.fetch!(alias_por_id, &1.id)}")

  arcos = Enum.map(transiciones, fn t ->
    origen = if t.estado_origen_id, do: Map.get(alias_por_id, t.estado_origen_id, "?"), else: "[*]"
    destino = Map.get(alias_por_id, t.estado_destino_id, "?")
    "    #{origen} --> #{destino} : #{escapar_mermaid(t.accion)}"
  end)

  estilos = estados |> Enum.filter(& &1.color)
            |> Enum.map(&estilo_color(Map.fetch!(alias_por_id, &1.id), &1.color))

  (["stateDiagram-v2"] ++ declaraciones ++ iniciales ++ arcos ++ estilos) |> Enum.join("\n")
end
```

Puntos de diseño concretos:

- **Alias cortos (`e1`, `e2`, ...)** en vez del nombre real como id de
  nodo (R3) — Mermaid exige identificadores sin espacios/acentos; el
  nombre real solo aparece como ETIQUETA (`state "<orden> - <nombre>"
  as e1`), nunca como identificador.
- **`escapar_mermaid/1`** (`bc_motor_live.ex:2180`) solo quita
  comillas dobles (`String.replace(texto, "\"", "")`) — suficiente
  para no romper la sintaxis de Mermaid (las etiquetas van entre
  comillas), no es un escapado genérico de caracteres especiales de
  Mermaid.
- **Color por estado** (R6): `estilo_color/2` genera una línea `style
  <id> fill:<hex>,stroke:<hex>,color:<legible>` — Mermaid soporta
  `style` sobre nodos de `stateDiagram-v2` igual que en un flowchart.
  `color_texto_legible/1` calcula luminancia YIQ
  (`0.299r + 0.587g + 0.114b`, umbral 150) para elegir texto claro u
  oscuro automáticamente sobre el fill elegido — mismo criterio que
  cualquier cálculo de contraste texto/fondo estándar.

## 3. Renderizado (R7-R9)

`diagrama_transiciones/1` (`bc_motor_live.ex:3090-3109`) renderiza un
único `<div id="diagrama-motor" phx-hook="DiagramaMotor"
phx-update="ignore" data-diagrama={@diagrama}>` con el texto
"Cargando diagrama…" como contenido inicial (servidor).

El hook (`assets/js/app.js`, `DiagramaMotor`):

```js
const cargarMermaid = () => {
  if (window.mermaid) return Promise.resolve(window.mermaid)
  if (cargaMermaid) return cargaMermaid

  cargaMermaid = new Promise((resolve, reject) => {
    const script = document.createElement("script")
    script.src = "/vendor/mermaid.min.js"
    script.onload = () => resolve(window.mermaid)
    script.onerror = () => reject(new Error("no se pudo cargar mermaid.min.js"))
    document.head.appendChild(script)
  })

  return cargaMermaid
}
```

`cargarMermaid/0` es un loader memoizado a nivel de módulo JS
(`cargaMermaid`, variable de closure) — la primera vez que CUALQUIER
diagrama de la página lo necesita, inyecta un `<script src="/vendor/mermaid.min.js">`
y cachea la Promise; cualquier otro diagrama (incluso de otro hook,
si alguna vez hay más de uno en la misma página) reusa `window.mermaid`
directo, sin volver a pedir el archivo (R7 — sin CDN externa, un solo
archivo vendorizado).

`pintar()` (async): `mermaid.initialize({startOnLoad: false, theme:
"neutral", securityLevel: "strict"})` + `mermaid.render(id,
definicion)` devuelve el SVG como string, que se inyecta directo en
`this.el.innerHTML`. `securityLevel: "strict"` sanitiza cualquier
HTML embebido en las etiquetas del diagrama (defensa en profundidad —
los nombres de estado/acción salen de datos que un administrador de
BC ya controla, no de un usuario final, pero el costo de la opción es
cero). Un error de render (definición inválida, fallo de red al
cargar la librería) cae al `catch`: reemplaza el contenido por "No se
pudo dibujar el diagrama." y registra el error en consola (R9) — sin
esto, un error async no manejado se pierde en silencio y el usuario
se queda mirando "Cargando diagrama…" para siempre.

## 4. Refresco en vivo (R10) — corregido 2026-09-11

**Antes de esta spec**: `DiagramaMotor` solo implementaba
`mounted()`. `phx-update="ignore"` le dice a LiveView que nunca
parchee el CONTENIDO de ese `<div>` (imprescindible — si no, cada
re-render del LiveView reemplazaría el SVG que Mermaid ya inyectó por
el `data-diagrama` en texto plano del último render del servidor,
perdiendo el dibujo). Lo que NO hacía `phx-update="ignore"` es
proteger los ATRIBUTOS del propio elemento — `data-diagrama` SÍ se
actualiza en el DOM en cada diff donde `@diagrama` cambió, y Phoenix
LiveView dispara el callback `updated()` del hook cada vez que el
elemento al que está enganchado recibe un patch de atributos, aunque
su contenido esté con `phx-update="ignore"`. Sin un `updated()`
definido, ese evento se perdía — el `<div>` tenía el `data-diagrama`
nuevo pero el SVG en pantalla seguía siendo el viejo hasta un F5.

**Fix**: agregado `updated()`, que llama al mismo `pintar()` que
`mounted()`. Para no volver a correr `mermaid.render()` en cada
`updated()` que dispare por cualquier otro motivo (una fila del
mismo LiveView que no toca este `<div>` puede seguir generando
diffs), `pintar()` ahora compara `definicion` contra
`this.definicionPintada` (guardado la última vez que SÍ redibujó) y
sale temprano si son iguales:

```js
const DiagramaMotor = {
  async mounted() {
    this.definicionPintada = null
    await this.pintar()
  },
  async updated() {
    await this.pintar()
  },
  async pintar() {
    const definicion = this.el.dataset.diagrama
    if (!definicion || definicion === this.definicionPintada) return
    // ...mermaid.render(...) + this.el.innerHTML = svg...
    this.definicionPintada = definicion
  },
}
```

No hace falta ningún cambio del lado servidor — `@diagrama` ya se
recalculaba en cada `cargar_motor/1` desde antes de este fix; lo
único que faltaba era que el cliente reaccionara a ese dato nuevo.

## 5. Fuera de alcance

Igual que `requirements.md` §5 — edición de estados/transiciones
(spec de Configuración).
