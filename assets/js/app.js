// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//
// If you have dependencies that try to import CSS, esbuild will generate a separate `app.css` file.
// To load it, simply add a second `<link>` to your `root.html.heex` file.

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/metadata_app"
import topbar from "../vendor/topbar"
import Sortable from "../vendor/sortable"
import GridEditable from "./hooks/grid_editable"
import RenglonForm from "./hooks/renglon_form"
import ReferenciaField from "./hooks/referencia_field"
import GridConstructor from "./hooks/grid_constructor"
import RelacionCampos from "./hooks/relacion_campos"
import FormatoCapturaField from "./hooks/formato_captura_field"
import FormatoNumericoField from "./hooks/formato_numerico_field"

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")

// Arrastrar la manija del borde del sidebar ajusta su ancho (guardado en
// localStorage — persiste entre recargas/páginas, ya que cada ruta es un
// mount de LiveView nuevo, no una sola SPA). Min/max evitan un sidebar
// inutilizablemente angosto o que se coma toda la pantalla.
const ANCHO_MIN = 200
const ANCHO_MAX = 480
const LLAVE_LOCALSTORAGE = "pc-sidebar-width"

const RedimensionarSidebar = {
  mounted() {
    const sidebar = this.el.closest(".pc-platform-sidebar")
    if (!sidebar) return

    // La variable CSS se pone en <html>, no en el <aside> — el sidebar se
    // vuelve a pintar seguido (ítem activo, campanita de notificaciones,
    // etc.) y un re-render de LiveView borraría un estilo puesto ahí. <html>
    // queda totalmente fuera de lo que LiveView parchea, así que sobrevive,
    // y la variable igual llega al sidebar por herencia normal de CSS.
    const raiz = document.documentElement

    const guardado = localStorage.getItem(LLAVE_LOCALSTORAGE)
    if (guardado) raiz.style.setProperty("--pc-sidebar-width", `${guardado}px`)

    let arrastrando = false

    const alMover = (e) => {
      if (!arrastrando) return
      const rect = sidebar.getBoundingClientRect()
      const ancho = Math.min(Math.max(e.clientX - rect.left, ANCHO_MIN), ANCHO_MAX)
      raiz.style.setProperty("--pc-sidebar-width", `${ancho}px`)
    }

    const alSoltar = () => {
      if (!arrastrando) return
      arrastrando = false
      sidebar.classList.remove("pc-resizing")
      this.el.classList.remove("pc-resizing")
      const ancho = raiz.style.getPropertyValue("--pc-sidebar-width")
      if (ancho) localStorage.setItem(LLAVE_LOCALSTORAGE, parseInt(ancho, 10))
    }

    this.el.addEventListener("mousedown", (e) => {
      arrastrando = true
      sidebar.classList.add("pc-resizing")
      this.el.classList.add("pc-resizing")
      e.preventDefault()
    })

    window.addEventListener("mousemove", alMover)
    window.addEventListener("mouseup", alSoltar)

    this._alMover = alMover
    this._alSoltar = alSoltar
  },
  destroyed() {
    window.removeEventListener("mousemove", this._alMover)
    window.removeEventListener("mouseup", this._alSoltar)
  },
}

// Mismo mecanismo que RedimensionarSidebar de arriba, pero para el panel
// flotante (pc-sidebar-flyout) que muestra las opciones de una carpeta
// raíz — su propia variable CSS/llave de localStorage, así ajustar uno no
// mueve al otro.
const ANCHO_MIN_FLYOUT = 180
const ANCHO_MAX_FLYOUT = 420
const LLAVE_LOCALSTORAGE_FLYOUT = "pc-flyout-width"

const RedimensionarFlyout = {
  mounted() {
    const flyout = this.el.closest(".pc-sidebar-flyout")
    if (!flyout) return

    const raiz = document.documentElement

    const guardado = localStorage.getItem(LLAVE_LOCALSTORAGE_FLYOUT)
    if (guardado) raiz.style.setProperty("--pc-flyout-width", `${guardado}px`)

    let arrastrando = false

    const alMover = (e) => {
      if (!arrastrando) return
      const rect = flyout.getBoundingClientRect()
      const ancho = Math.min(Math.max(e.clientX - rect.left, ANCHO_MIN_FLYOUT), ANCHO_MAX_FLYOUT)
      raiz.style.setProperty("--pc-flyout-width", `${ancho}px`)
    }

    const alSoltar = () => {
      if (!arrastrando) return
      arrastrando = false
      flyout.classList.remove("pc-resizing")
      this.el.classList.remove("pc-resizing")
      const ancho = raiz.style.getPropertyValue("--pc-flyout-width")
      if (ancho) localStorage.setItem(LLAVE_LOCALSTORAGE_FLYOUT, parseInt(ancho, 10))
    }

    this.el.addEventListener("mousedown", (e) => {
      arrastrando = true
      flyout.classList.add("pc-resizing")
      this.el.classList.add("pc-resizing")
      e.preventDefault()
    })

    window.addEventListener("mousemove", alMover)
    window.addEventListener("mouseup", alSoltar)

    this._alMover = alMover
    this._alSoltar = alSoltar
  },
  destroyed() {
    window.removeEventListener("mousemove", this._alMover)
    window.removeEventListener("mouseup", this._alSoltar)
  },
}

// El colapsado/expandido del sidebar (@sidebar_open) es un assign de
// SERVIDOR, distinto de tema/ancho (que son 100% del cliente) — cada
// ruta es un mount de LiveView nuevo que hardcodea sidebar_open: false,
// así que sin esto el menú se cerraba solo al navegar a otra página. Acá
// se guarda el estado real (después de cualquier toggle) en localStorage
// y, en cada mount nuevo, si lo guardado no coincide con lo que el
// servidor acaba de renderizar, se dispara el mismo evento "toggle_sidebar"
// que ya usa el botón de colapsar — un viaje de ida y vuelta corto, no
// hay forma de que el servidor sepa esto ANTES de renderizar la primera
// vez (a diferencia del tema, que se aplica con un <script> en el <head>
// antes de que exista ningún contenido del servidor).
const LLAVE_SIDEBAR_ABIERTO = "pc-sidebar-open"

const PersistirSidebarAbierto = {
  mounted() {
    const estaAbierto = () => this.el.classList.contains("pc-platform-sidebar-open")

    const guardado = localStorage.getItem(LLAVE_SIDEBAR_ABIERTO)
    if (guardado !== null && (guardado === "true") !== estaAbierto()) {
      this.pushEvent("change_page", { id: "toggle_sidebar" })
    }

    this._observer = new MutationObserver(() => {
      localStorage.setItem(LLAVE_SIDEBAR_ABIERTO, estaAbierto())
    })
    this._observer.observe(this.el, { attributes: true, attributeFilter: ["class"] })
  },
  destroyed() {
    this._observer?.disconnect()
  },
}

// Una carpeta raíz del riel (.pc-menu-carpeta-summary-raiz, ver
// menu_nodos/1 en menu_layout.ex) controla su propio [open] a mano —
// abrir el flyout siempre colapsa el riel (o viceversa), un
// JS.set_attribute/JS.remove_attribute explícito en el phx-click. El
// problema: un <summary> dentro de un <details> SIEMPRE togglea su
// padre como "acción por default" del click, sin importar qué haga
// el phx-click — carrera confirmada con un MutationObserver: el
// atributo queda en true, y ~6-10ms después el toggle nativo lo
// revierte (o lo vuelve a poner, según el estado de arranque),
// pisando lo que se acababa de pedir. preventDefault() acá, en fase de
// CAPTURA (antes de que el navegador dispare esa acción por default),
// lo bloquea del todo — no hace stopPropagation, así que el phx-click
// de LiveView (que escucha en burbuja) sigue disparando normal.
const EvitarToggleNativoCarpetas = {
  mounted() {
    this._alClick = (e) => {
      if (e.target.closest(".pc-menu-carpeta-summary-raiz")) e.preventDefault()
    }
    this.el.addEventListener("click", this._alClick, true)
  },
  destroyed() {
    this.el.removeEventListener("click", this._alClick, true)
  },
}

// Filtra el árbol del menú sin ir al servidor — el menú se pinta en varias
// pantallas (InicioLive, CatalogoLive, BcListLive, BcMotorLive...), así que
// resolverlo del lado del cliente evita cablear el mismo estado de búsqueda
// en cada una. Oculta ítems que no matchean, y una carpeta se oculta solo
// si NINGÚN descendiente (página o subcarpeta) matchea; si alguno matchea,
// se abre sola para que se vea.
const FiltroMenu = {
  mounted() {
    this.el.addEventListener("input", (e) => this.filtrar(e.target.value, e.target))
  },
  // Si lo que hay en la caja es exactamente la ruta de una página real (por
  // ejemplo pegando lo que copiaste con el botón de las migas de pan), en
  // vez de filtrar por texto navega directo para allá — clickeamos el link
  // real para que LiveView haga su navegación normal (misma lógica que si
  // el usuario le diera clic).
  intentarNavegarPorRuta(query, elemento) {
    const q = query.trim()

    let candidato = q
    if (candidato.includes("://")) {
      try {
        candidato = new URL(candidato).pathname
      } catch (_e) {
        // No era una URL válida — se sigue tratando como ruta tal cual.
      }
    }

    if (!candidato.startsWith("/")) return false

    const nav = document.querySelector(".pc-sidebar-nav")
    if (!nav) return false

    const coincidencia = Array.from(nav.querySelectorAll(".pc-nav-item[href]")).find(
      (item) => item.getAttribute("href") === candidato
    )
    if (!coincidencia) return false

    elemento.value = ""
    coincidencia.click()
    return true
  },
  filtrar(query, elemento) {
    if (elemento && this.intentarNavegarPorRuta(query, elemento)) return

    const nav = document.querySelector(".pc-sidebar-nav")
    if (!nav) return
    const q = query.trim().toLowerCase()

    const carpetas = nav.querySelectorAll(".pc-menu-carpeta")
    const items = nav.querySelectorAll(".pc-nav-item")

    if (q === "") {
      carpetas.forEach((c) => {
        c.style.display = ""
        if (c.dataset.openOriginal !== undefined) c.open = c.dataset.openOriginal === "true"
      })
      items.forEach((i) => { i.style.display = "" })
      return
    }

    items.forEach((item) => {
      const label = item.querySelector(".pc-nav-label")
      const texto = label ? label.textContent.toLowerCase() : ""
      item.style.display = texto.includes(q) ? "" : "none"
    })

    // De adentro hacia afuera (querySelectorAll ya entrega las carpetas más
    // anidadas después de sus padres en el DOM, así que se recorre al
    // revés) para que una carpeta padre vea el resultado ya calculado de
    // sus hijas antes de decidir si ella misma se muestra.
    Array.from(carpetas).reverse().forEach((carpeta) => {
      if (carpeta.dataset.openOriginal === undefined) {
        carpeta.dataset.openOriginal = carpeta.open ? "true" : "false"
      }

      const hijoVisible = Array.from(carpeta.querySelectorAll(".pc-nav-item, .pc-menu-carpeta")).some(
        (hijo) => hijo.style.display !== "none"
      )

      if (hijoVisible) {
        carpeta.style.display = ""
        carpeta.open = true
      } else {
        carpeta.style.display = "none"
      }
    })
  },
}

// Botón de copiar en las migas de pan — copia la URL completa y compartible
// de la página activa (ej. "https://host/electronica/computo/mouses", no
// solo la ruta relativa) al portapapeles, para pegarla en la barra de
// búsqueda (ver FiltroMenu.intentarNavegarPorRuta) o compartirla con
// alguien que la pueda abrir directo. data-nav se repatchea en cada
// navegación (no tiene phx-update="ignore"), así que siempre lee la ruta
// más reciente al hacer clic, sin necesitar un hook nuevo por cada página
// visitada. window.location.origin se resuelve en el momento del click
// (no al montar), así que ya sale correcto detrás de cualquier proxy/dominio.
const CopiarRuta = {
  mounted() {
    this.el.addEventListener("click", () => this.copiar())
  },
  copiar() {
    const nav = this.el.dataset.nav
    if (!nav) return
    const url = window.location.origin + nav
    navigator.clipboard.writeText(url).then(() => {
      this.el.classList.add("pc-breadcrumb-copiado")
      clearTimeout(this._timeout)
      this._timeout = setTimeout(() => this.el.classList.remove("pc-breadcrumb-copiado"), 1200)
    })
  },
}

// <input type="date">/"time" de "Filtros por default" (bc_motor_live.ex,
// panel_filtros_default/1) y de campo_input_components.ex (tipo
// "date"/"hora"): antes este hook forzaba showPicker() en CUALQUIER clic
// o foco del campo, para que el iconito diminuto del calendario nativo no
// pasara desapercibido. Problema real (reporte de usuaria, campo "Fecha
// inicial"): con el overlay del picker abierto, Chromium le manda las
// teclas a la navegación del propio calendario en vez de a los segmentos
// dd/mm/aaaa del input — tipear la fecha a mano queda bloqueado del todo,
// no sólo el primer clic. Sacar el auto-abrir del todo tampoco sirve: el
// iconito nativo es tan chico (y a veces invisible del todo, ver CSS)
// que en la práctica nadie lo encuentra para abrir el picker con el
// mouse. Solución: el iconito nativo se oculta por completo (CSS) y en
// su lugar cada campo trae un botón de flechita real y visible
// (`[data-abrir-calendario]`, mismo div contenedor que el input) — sólo
// ESE botón dispara showPicker(), nunca un clic en el campo de texto.
const AbrirCalendario = {
  mounted() {
    if (this.el.dataset.destino) {
      // Modo "fecha" de "Formato de captura" (campo_input_components.ex):
      // este <input type="date"> vive oculto (sr-only) al lado de un
      // input de texto con máscara "99/99/9999" — `data-destino` es el
      // id de ESE input. Acá SÍ hace falta forzar el picker en cualquier
      // clic (el input real nunca se ve ni se tipea directamente, sólo
      // se llega a él por su <label> "calendar_month", nunca por un clic
      // "de tipear"). Elegir una fecha ahí escribe el valor YA formateado
      // en el input de texto (en vez de reemplazarlo por un date input
      // real, que perdería la posibilidad de seguir tipeando el patrón a
      // mano) y dispara "input" para que el phx-change de siempre la vea.
      this.el.addEventListener("click", () => this.abrir())
      this.el.addEventListener("change", () => this.sincronizar())
    } else {
      const boton = this.el.parentElement?.querySelector("[data-abrir-calendario]")
      if (boton) boton.addEventListener("click", () => this.abrir())
    }
  },
  abrir() {
    if (typeof this.el.showPicker === "function") this.el.showPicker()
  },
  sincronizar() {
    const destino = document.getElementById(this.el.dataset.destino)
    if (!destino || !this.el.value) return
    const [anio, mes, dia] = this.el.value.split("-")
    destino.value = `${dia}/${mes}/${anio}`
    destino.dispatchEvent(new Event("input", {bubbles: true}))
    destino.focus()
  },
}

// "Recordar si el usuario la dejó abierta" de Sección (ficha_live.ex,
// nodo_plantilla_render/1 "seccion" colapsable) — <details> nativo,
// 100% del lado del cliente (localStorage, sin round-trip al servidor):
// el navegador ya togglea open/close solo con el <summary>, esto solo
// recuerda esa elección entre visitas. Clave por id de nodo (único
// dentro de la plantilla) -- el evento "toggle" es nativo de <details>.
const RecordarSeccion = {
  mounted() {
    const llave = `pc-seccion-${this.el.id}`
    const guardado = localStorage.getItem(llave)
    if (guardado !== null) this.el.open = guardado === "true"

    this.el.addEventListener("toggle", () => localStorage.setItem(llave, this.el.open))
  },
}

// Vista de impresión de la Ficha 360° (?imprimir=1, ver render/1 en
// ficha_live.ex): esa pestaña nueva no tiene ningún botón "Imprimir" propio
// (sería el mismo botón que la abrió) — dispara el diálogo de impresión del
// navegador solo, al montar.
const AutoImprimir = {
  mounted() {
    window.print()
  },
}

// Zoom del lienzo del Constructor (PlantillaConstructorLive.grid_editor/1,
// botones +/-/Ajustar) — 100% cliente, nunca pushEvent al servidor (no
// cambia nada de la definición, solo cómo se ve mientras se edita).
// this.el es el contenedor de los 3 botones + la etiqueta de porcentaje;
// data-target apunta al id del elemento que se escala de verdad.
const ZoomLienzo = {
  mounted() {
    this.zoom = 100
    const objetivo = document.getElementById(this.el.dataset.target)
    const label = this.el.querySelector("[data-zoom-label]")
    const aplicar = () => {
      objetivo.style.transform = `scale(${this.zoom / 100})`
      label.textContent = `${this.zoom}%`
    }
    this.el.querySelector("[data-zoom-in]").addEventListener("click", () => {
      this.zoom = Math.min(200, this.zoom + 10)
      aplicar()
    })
    this.el.querySelector("[data-zoom-out]").addEventListener("click", () => {
      this.zoom = Math.max(40, this.zoom - 10)
      aplicar()
    })
    this.el.querySelector("[data-zoom-fit]").addEventListener("click", () => {
      this.zoom = 100
      aplicar()
    })
  },
}

// Selector de columnas visibles + orden ("Campos", ver panel_campos/1 en
// catalogo_live.ex) — 100% del lado del cliente, sin un solo evento al
// servidor: tildar/destildar/arrastrar un campo solo oculta/reordena
// <th>/<td> por CSS/DOM (display:none, appendChild), nunca toca @columnas
// ni la query real. El estado vive acá, a nivel de MÓDULO — no en
// localStorage a propósito — indexado por la ruta actual:
//   - Sobrevive una navegación LiveView (push_navigate/<.link navigate>)
//     porque esas NO recargan la página de verdad; el módulo de JS sigue
//     vivo en memoria, solo se re-monta el hook con el mismo estado.
//   - Se borra solo con un refresh real del navegador (F5/Ctrl+R), que
//     reinicia todo el runtime de JS — exactamente el comportamiento
//     pedido: "momentáneo", nunca localStorage.
const memoriaColumnasOcultas = {}
const memoriaOrdenColumnas = {}

const SelectorCampos = {
  mounted() {
    this.tabla = document.getElementById(this.el.dataset.tabla)
    this.clave = window.location.pathname
    this.buscador = this.el.querySelector("[data-buscador-campo]")
    this.lista = this.el.querySelector("[data-lista-campos]")

    // Orden tal cual lo mandó el servidor (antes de restaurar nada) — es
    // lo que "Limpiar filtro de campos" restaura, y lo que guardarOrden/1
    // usa para decidir si hay override que guardar o no.
    this.ordenOriginal = this.ordenActual()

    const ordenGuardado = memoriaOrdenColumnas[this.clave]
    if (ordenGuardado) this.reordenarLista(ordenGuardado)

    const ocultos = memoriaColumnasOcultas[this.clave] || this.ocultosPorDefecto()
    this.casillas().forEach((cb) => { cb.checked = !ocultos.includes(cb.dataset.campo) })

    this.aplicar()
    this.aplicarOrden()

    this.el.addEventListener("change", (e) => {
      if (!e.target.matches("input[type=checkbox][data-campo]")) return
      this.aplicar()
      this.guardar()
    })

    this.el.addEventListener("click", (e) => {
      const boton = e.target.closest("[data-accion]")
      if (!boton) return

      if (boton.dataset.accion === "seleccionar-todos") this.casillas().forEach((cb) => (cb.checked = true))
      if (boton.dataset.accion === "deseleccionar-todos") this.casillas().forEach((cb) => (cb.checked = false))

      if (boton.dataset.accion === "limpiar") {
        this.casillas().forEach((cb) => (cb.checked = true))
        this.reordenarLista(this.ordenOriginal)
        if (this.buscador) this.buscador.value = ""
        this.filtrarLista("")
      }

      this.aplicar()
      this.aplicarOrden()
      this.guardar()
      this.guardarOrden()
    })

    this.buscador?.addEventListener("input", (e) => this.filtrarLista(e.target.value))

    if (this.lista) {
      this.sortable = new Sortable(this.lista, {
        animation: 120,
        handle: ".jal-manija",
        ghostClass: "jal-fantasma",
        onEnd: () => {
          this.aplicarOrden()
          this.guardarOrden()
        },
      })
    }
  },

  destroyed() {
    this.sortable?.destroy()
  },

  casillas() {
    return this.el.querySelectorAll("input[type=checkbox][data-campo]")
  },

  // En celular, sin que el usuario haya tocado "Campos" todavía en esta
  // sesión (ver memoriaColumnasOcultas arriba), arranca ocultando las
  // columnas "estructurales" (Estado/TRN/Empresa/Sucursal/Almacén/Unidad
  // de venta) — son las que más empujan la tabla a scroll horizontal en
  // una pantalla angosta, y casi nunca son el dato que alguien busca de
  // un vistazo. Siguen ahí, un tilde en "Campos" las trae de vuelta. En
  // desktop (>= 640px, mismo corte que el resto de la vista) no cambia
  // nada de lo que ya había.
  ocultosPorDefecto() {
    if (!window.matchMedia("(max-width: 639px)").matches) return []
    const estructurales = ["estado", "trn", "empresa", "branch", "inventory_location", "sales_unit"]
    return Array.from(this.casillas())
      .map((cb) => cb.dataset.campo)
      .filter((clave) => estructurales.includes(clave))
  },

  ordenActual() {
    return Array.from(this.casillas()).map((cb) => cb.dataset.campo)
  },

  // Reordena las filas [data-fila-campo] del popover (no la tabla) según
  // una lista de claves — mueve cada <div> a su posición vía appendChild
  // repetido, el mismo truco que usa aplicarOrden/reordenarFila para las
  // celdas de la tabla.
  reordenarLista(ordenClaves) {
    if (!this.lista) return
    const filas = Array.from(this.lista.querySelectorAll("[data-fila-campo]"))
    const mapa = new Map(filas.map((fila) => [fila.querySelector("input[data-campo]")?.dataset.campo, fila]))
    ordenClaves.forEach((clave) => {
      const fila = mapa.get(clave)
      if (fila) this.lista.appendChild(fila)
    })
  },

  filtrarLista(texto) {
    const q = texto.toLowerCase()
    this.el.querySelectorAll("[data-fila-campo]").forEach((fila) => {
      const etiqueta = (fila.dataset.etiqueta || "").toLowerCase()
      fila.style.display = etiqueta.includes(q) ? "" : "none"
    })
  },

  aplicar() {
    if (!this.tabla) return
    this.casillas().forEach((cb) => {
      const visible = cb.checked
      this.tabla.querySelectorAll(`[data-col="${CSS.escape(cb.dataset.campo)}"]`).forEach((celda) => {
        celda.style.display = visible ? "" : "none"
      })
    })
  },

  // Reordena las celdas [data-col] de CADA fila de la tabla (thead/tbody/
  // tfoot por igual, misma consulta genérica) según el orden actual del
  // popover — las celdas SIN data-col (la columna de Acciones al final)
  // se dejan tal cual, al final, en su lugar de siempre.
  aplicarOrden() {
    if (!this.tabla) return
    const orden = this.ordenActual()
    this.tabla.querySelectorAll("tr").forEach((fila) => this.reordenarFila(fila, orden))
  },

  reordenarFila(fila, orden) {
    const celdas = Array.from(fila.children)
    const conCol = celdas.filter((c) => c.dataset.col)
    const sinCol = celdas.filter((c) => !c.dataset.col)
    const mapa = new Map(conCol.map((c) => [c.dataset.col, c]))
    const ordenadas = orden.map((clave) => mapa.get(clave)).filter(Boolean)
    const faltantes = conCol.filter((c) => !orden.includes(c.dataset.col))

    ;[...ordenadas, ...faltantes, ...sinCol].forEach((c) => fila.appendChild(c))
  },

  guardar() {
    const ocultos = Array.from(this.casillas())
      .filter((cb) => !cb.checked)
      .map((cb) => cb.dataset.campo)

    if (ocultos.length === 0) delete memoriaColumnasOcultas[this.clave]
    else memoriaColumnasOcultas[this.clave] = ocultos
  },

  guardarOrden() {
    const actual = this.ordenActual()
    const esOriginal =
      actual.length === this.ordenOriginal.length && actual.every((clave, i) => clave === this.ordenOriginal[i])

    if (esOriginal) delete memoriaOrdenColumnas[this.clave]
    else memoriaOrdenColumnas[this.clave] = actual
  },
}

// Aviso "cambiaste de Unidad Operativa" (2026-08-13) — detección 100%
// client-side, sin flash ni sesión de por medio: el server solo expone la
// firma ACTUAL (Empresa+Branch+Inventory, ver firma_unidad_operativa/1 en
// menu_layout.ex) en un elemento con phx-update="ignore" (nunca lo toca el
// diff de LiveView). Al montar, compara esa firma contra la última guardada
// en localStorage del navegador — si YA había una guardada y es distinta,
// significa que la Unidad Operativa cambió desde la última vez que este
// navegador vio una página (footer, cambio de empresa, etc.), y dispara el
// aviso. Primera visita nunca dispara (no hay firma previa contra qué
// comparar) — no tendría sentido avisar de un "cambio" que en realidad es
// solo la primera carga.
const UnidadOperativaWatcher = {
  mounted() {
    const clave = "pc_unidad_operativa_firma"
    const firma = this.el.dataset.firma
    const anterior = localStorage.getItem(clave)

    if (firma && anterior !== null && anterior !== firma) {
      this.avisar()
    }

    if (firma) localStorage.setItem(clave, firma)
  },

  avisar() {
    const modal = document.getElementById("modal-unidad-operativa")
    if (!modal) return

    this.setTexto("modal-unidad-operativa-empresa", this.el.dataset.empresa)
    this.setTexto("modal-unidad-operativa-branch", this.el.dataset.branch)
    this.setTexto("modal-unidad-operativa-inventory", this.el.dataset.inventory)
    // Unidad de Venta es opcional -- vacía en vez de omitirse, a
    // propósito (pedido explícito: "XX o vacía si es el caso").
    this.setTexto("modal-unidad-operativa-sales-unit", this.el.dataset.salesUnit || "")

    modal.classList.remove("hidden")
    // 1 segundo bloqueando la pantalla (overlay, no un toast que se
    // pueda ignorar de reojo) -- fricción deliberada para que el usuario
    // registre el cambio antes de seguir operando y evitar que arranque
    // a hacer algo en la Unidad Operativa equivocada por apuro. Bajado de
    // 5s a 3s y después a 1s (2026-08-15, a pedido explícito).
    clearTimeout(this.temporizador)
    this.temporizador = setTimeout(() => modal.classList.add("hidden"), 1000)
  },

  setTexto(id, valor) {
    const el = document.getElementById(id)
    if (el) el.textContent = valor || ""
  },

  destroyed() {
    clearTimeout(this.temporizador)
  },
}

// Copia el contenido de un <textarea> al portapapeles — usado en el editor
// de reglas PRE/POST de BcMotorLive (panel_reglas), para poder trabajar la
// regla en otro editor y volver a pegarla acá antes de "Compilar". Lee
// .value del textarea en el momento del click (no al montar), así copia lo
// que el usuario tiene tipeado ahora mismo, incluso si todavía no lo guardó.
// Copia un texto literal (data-texto) al portapapeles — genérico, a
// diferencia de CopiarRuta (arma una URL a partir de un nav) y
// CopiarTextarea (lee el .value de un <textarea> por id). Usado por el
// TRN de la Ficha 360° (PrettyCore TRN, Fase 3): informativo, para poder
// compartirlo/mapearlo después sin tener que seleccionarlo a mano.
const CopiarTexto = {
  mounted() {
    this.el.addEventListener("click", () => this.copiar())
  },
  copiar() {
    const texto = this.el.dataset.texto
    if (!texto) return
    navigator.clipboard.writeText(texto).then(() => {
      this.el.classList.add("pc-breadcrumb-copiado")
      clearTimeout(this._timeout)
      this._timeout = setTimeout(() => this.el.classList.remove("pc-breadcrumb-copiado"), 1200)
    })
  },
}

const CopiarTextarea = {
  mounted() {
    this.el.addEventListener("click", () => this.copiar())
  },
  copiar() {
    const targetId = this.el.dataset.target
    const textarea = targetId && document.getElementById(targetId)
    if (!textarea) return
    navigator.clipboard.writeText(textarea.value).then(() => {
      const original = this.el.textContent
      this.el.textContent = "Copiado"
      clearTimeout(this._timeout)
      this._timeout = setTimeout(() => { this.el.textContent = original }, 1200)
    })
  },
}

// Aviso de "salir sin guardar" para el editor de reglas PRE/POST
// (panel_reglas en BcMotorLive) — el <textarea> NO tiene phx-change (ver
// CopiarTextarea más arriba: se lee .value recién al copiar/compilar), así
// que mientras se tipea el servidor no se entera de nada. Si se navega a
// otra pantalla sin darle "Compilar" antes, ese texto se pierde entero sin
// aviso (LiveView desmonta esta vista). Un hook por textarea (PRE y POST
// por separado, cada uno con su propio data-tipo) compara el valor actual
// contra el que había al montar (= lo último realmente compilado, porque
// bloque_regla/1 siempre renderiza fila.codigo_fuente de la base) — si
// difieren, intercepta tanto el cierre/recarga de pestaña (beforeunload)
// como un click en cualquier link/botón de navegación interna de
// LiveView (data-phx-link de <.link navigate>/<.link patch>, o los
// botones del sidebar con phx-click="change_page").
const AvisoReglasSinGuardar = {
  mounted() {
    this.original = this.el.value

    this.alDescargar = (e) => {
      if (this.el.value === this.original) return
      e.preventDefault()
      e.returnValue = ""
    }
    window.addEventListener("beforeunload", this.alDescargar)

    this.alHacerClick = (e) => {
      if (this.el.value === this.original) return

      const destino = e.target.closest('[data-phx-link], [phx-click="change_page"]')
      if (!destino || this.el.contains(destino)) return

      if (!window.confirm("Tienes cambios sin compilar, ¿seguro que quieres salir?")) {
        e.preventDefault()
        e.stopImmediatePropagation()
      }
    }
    document.addEventListener("click", this.alHacerClick, true)

    // El servidor avisa acá cuando ESTE tipo (pre/post) se compiló de
    // verdad (validar_guardar_y_compilar/3) — recién ahí el valor actual
    // pasa a ser "lo último guardado", no antes (un intento fallido por
    // error de sintaxis no cuenta: nada se guardó, sigue pendiente).
    this.handleEvent("regla_guardada", ({tipo}) => {
      if (tipo === this.el.dataset.tipo) this.original = this.el.value
    })
  },
  destroyed() {
    window.removeEventListener("beforeunload", this.alDescargar)
    document.removeEventListener("click", this.alHacerClick, true)
  },
}

// Diagrama de estados del Motor (BcMotorLive) — Mermaid pesa ~3.5MB, así
// que se carga on-demand (script inyectado dinámicamente) solo cuando este
// hook monta, no en el bundle principal que se sirve en cada página.
let cargaMermaid = null
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

const DiagramaMotor = {
  async mounted() {
    await this.pintar()
  },
  async pintar() {
    const definicion = this.el.dataset.diagrama
    if (!definicion) return

    try {
      const mermaid = await cargarMermaid()
      mermaid.initialize({startOnLoad: false, theme: "neutral", securityLevel: "strict"})
      const {svg} = await mermaid.render(`svg-${this.el.id}`, definicion)
      this.el.innerHTML = svg
    } catch (e) {
      this.el.textContent = "No se pudo dibujar el diagrama."
      console.error("[DiagramaMotor]", e)
    }
  },
}

// Arrastrar y soltar real — usado tanto en el Constructor de plantillas
// (PlantillaConstructorLive) como en "Editar vista" de BcListLive.
//
// `group` viene de `data-grupo` si el contenedor lo trae, si no cae al
// hardcodeado de siempre ("plantilla-componentes") — así el Constructor de
// plantillas sigue exactamente igual (todas sus listas comparten ese mismo
// group a propósito, para poder arrastrar un componente de una lista a
// otra, ej. sacarlo de una Sección y dejarlo suelto en la raíz).
// "Editar vista", en cambio, SÍ le pasa un `data-grupo` propio y ÚNICO por
// cada carpeta — ahí cada contenedor tiene que quedar aislado (reordenar
// DENTRO de una carpeta, nunca arrastrar accidentalmente un catálogo a
// otra carpeta distinta sin querer, que le cambiaría la ruta de navegación
// de golpe sin ninguna confirmación).
//
// Sortable muta el DOM al soltar (optimista); el servidor recién después
// reordena de verdad y LiveView repinta — por eso `animation` bajo y sin
// esperar nada del servidor para que se sienta instantáneo, aunque el
// estado real siempre termina siendo el que decide el servidor (si el push
// falla o tarda, el próximo repintado corrige cualquier diferencia).
const ListaOrdenable = {
  mounted() {
    this.sortable = new Sortable(this.el, {
      group: this.el.dataset.grupo || "plantilla-componentes",
      animation: 120,
      handle: ".jal-manija",
      ghostClass: "jal-fantasma",
      onEnd: (evt) => {
        const id = evt.item.dataset.id
        const contenedorId = evt.to.dataset.contenedorId || ""
        if (!id) return
        this.pushEvent("mover_a", {id, contenedor_id: contenedorId, index: evt.newIndex})
      },
    })
  },
  destroyed() {
    this.sortable && this.sortable.destroy()
  },
}

// Botón "Vista previa" del Constructor: el servidor guarda el borrador y
// recién después empuja este evento (ver handle_event("vista_previa", ...)
// en PlantillaConstructorLive) — abrir la pestaña nueva es la única parte
// que el servidor no puede hacer solo. `window.open` DENTRO de
// handleEvent llega tarde (después del viaje de ida y vuelta al
// servidor) y el navegador lo bloquea como pop-up porque ya no lo ve como
// resultado directo del click — por eso la pestaña se abre en blanco acá
// mismo, de forma síncrona en el click, y recién se le pone la URL real
// cuando el servidor confirma que guardó.
const AbrirVistaPrevia = {
  mounted() {
    this.pestanaPrevia = null

    this.el.addEventListener("click", () => {
      this.pestanaPrevia = window.open("", "_blank")
    })

    this.handleEvent("abrir_vista_previa", ({url}) => {
      if (this.pestanaPrevia && !this.pestanaPrevia.closed) this.pestanaPrevia.location = url
      else window.open(url, "_blank")
    })

    this.handleEvent("cancelar_vista_previa", () => {
      if (this.pestanaPrevia && !this.pestanaPrevia.closed) this.pestanaPrevia.close()
      this.pestanaPrevia = null
    })
  },
}

const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {...colocatedHooks, FiltroMenu, RedimensionarSidebar, RedimensionarFlyout, PersistirSidebarAbierto, EvitarToggleNativoCarpetas, CopiarRuta, CopiarTexto, CopiarTextarea, SelectorCampos, AvisoReglasSinGuardar, DiagramaMotor, ListaOrdenable, AbrirVistaPrevia, GridEditable, RenglonForm, ReferenciaField, GridConstructor, RelacionCampos, AbrirCalendario, FormatoCapturaField, FormatoNumericoField, UnidadOperativaWatcher, RecordarSeccion, AutoImprimir, ZoomLienzo},
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// connect if there are any LiveViews on the page
liveSocket.connect()

// bfcache (Back/Forward Cache) del navegador: al volver a una página con
// atrás/adelante, Chrome a veces la restaura CONGELADA en vez de
// recargarla de cero -- el socket de LiveView queda cerrado ("Page
// entered Back-Forward Cache" en la consola) pero el DOM se ve intacto,
// así que cualquier phx-click/phx-change se queda mudo sin ningún aviso
// visible (bug real reportado: "Activar" en una plantilla no hacía
// nada). `pageshow` con `event.persisted` es la señal estándar de que la
// página viene de bfcache -- forzar un reload real reconecta el socket
// en vez de dejar la página zombie.
window.addEventListener("pageshow", (event) => {
  if (event.persisted) window.location.reload()
})

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    // Enable server log streaming to client.
    // Disable with reloader.disableServerLogs()
    reloader.enableServerLogs()

    // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
    //
    //   * click with "c" key pressed to open at caller location
    //   * click with "d" key pressed to open at function component definition location
    let keyDown
    window.addEventListener("keydown", e => keyDown = e.key)
    window.addEventListener("keyup", e => keyDown = null)
    window.addEventListener("click", e => {
      if(keyDown === "c"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtCaller(e.target)
      } else if(keyDown === "d"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtDef(e.target)
      }
    }, true)

    window.liveReloader = reloader
  })
}

