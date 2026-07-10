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

const AbrirVentana = {
  mounted() {
    this.el.addEventListener("click", (e) => {
      e.preventDefault()
      window.open(this.el.dataset.url, "_blank", "width=1000,height=800")
    })
  },
}

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
// pantallas (InicioLive, CatalogoLive, BcListLive, BcNuevoLive...), así que
// resolverlo del lado del cliente evita cablear el mismo estado de búsqueda
// en cada una. Oculta ítems que no matchean, y una carpeta se oculta solo
// si NINGÚN descendiente (página o subcarpeta) matchea; si alguno matchea,
// se abre sola para que se vea.
const FiltroMenu = {
  mounted() {
    this.el.addEventListener("input", (e) => this.filtrar(e.target.value))
  },
  filtrar(query) {
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

const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {...colocatedHooks, AbrirVentana, FiltroMenu, RedimensionarSidebar},
})

// La pantalla que se abre en la ventana emergente (ej. BC Nuevo) dispara este
// evento al terminar de guardar, para autocerrarse. window.close() solo
// funciona en ventanas abiertas por script (window.open), por eso el botón
// usa el hook AbrirVentana en vez de un <a target="_blank"> normal.
window.addEventListener("phx:cerrar_ventana", () => window.close())

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

