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

// Copia el contenido de un <textarea> al portapapeles — usado en el editor
// de reglas PRE/POST de BcMotorLive (panel_reglas), para poder trabajar la
// regla en otro editor y volver a pegarla acá antes de "Compilar". Lee
// .value del textarea en el momento del click (no al montar), así copia lo
// que el usuario tiene tipeado ahora mismo, incluso si todavía no lo guardó.
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

const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {...colocatedHooks, FiltroMenu, RedimensionarSidebar, CopiarRuta, CopiarTextarea, DiagramaMotor},
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// connect if there are any LiveViews on the page
liveSocket.connect()

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

