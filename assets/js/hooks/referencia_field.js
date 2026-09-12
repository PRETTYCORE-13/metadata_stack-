// ReferenciaField — combobox de filtro LOCAL para campos tipo "referencia"
// en FichaLive.formulario_renglon/1 (ver campo_input_components.ex). Las
// opciones ({id, etiqueta}) ya vienen resueltas del lado del servidor
// (mismo picker que antes era un <select> simple) — acá solo se filtran en
// el cliente, sin ida y vuelta al servidor.
//
// Elegir una opción escribe en el input hidden y dispara un evento "input"
// nativo (bubbles: true) sobre él — el phx-change de siempre en el <form>
// de afuera lo recoge igual que cualquier otro campo tocado a mano, sin
// pushEvent propio acá.
//
// La lista SOLO se abre con F2 o al tipear — nunca al enfocar (Tab) — así
// un Tab/Enter que solo pasa de largo por un campo referencia con un valor
// ya correcto no dispara de rebote una selección accidental del primer
// resultado. Cuando la lista está cerrada, Enter/Escape no se interceptan
// acá — burbujean tal cual al hook RenglonForm del formulario (avanzar de
// campo / cancelar la línea).
function escaparHtml(valor) {
  return String(valor).replace(/[&<>"']/g, (c) => ({"&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;"}[c]))
}

export default {
  mounted() {
    this.hidden = this.el.querySelector("[data-campo-hidden]")
    this.texto = this.el.querySelector("[data-campo-texto]")
    this.lista = this.el.querySelector("[data-campo-lista]")
    this.resaltado = -1
    this.filtradas = []
    this.leerDataset()

    this.texto.addEventListener("keydown", (e) => this.onKeydown(e))
    this.texto.addEventListener("input", () => this.filtrar(this.texto.value))
    this.texto.addEventListener("blur", () => this.cerrar())
    this.lista.addEventListener("mousedown", (e) => this.onMousedownLista(e))

    // Cierra en vez de dejar la posición vieja (ver posicionarLista más
    // abajo) -- más simple que recalcular en cada scroll/resize, y el
    // usuario la reabre con una tecla. `capture: true` en scroll porque
    // el contenedor que hace scroll (no window) no burbujea el evento.
    //
    // Bug real (2026-09-12): con `capture: true` en window, esto también
    // capta el scroll INTERNO de la propia lista (arrastrar su scrollbar
    // cuando hay muchas opciones) y la cerraba de inmediato -- el usuario
    // nunca llegaba a ver el resto de los resultados. `e.target` de un
    // scroll disparado por la lista misma es la lista -- se ignora ese
    // caso, solo cierra si lo que hizo scroll fue algo AFUERA de ella.
    this.alScrollOCerrar = (e) => this.abierta() && !this.lista.contains(e.target) && this.cerrar()
    window.addEventListener("scroll", this.alScrollOCerrar, true)
    window.addEventListener("resize", this.alScrollOCerrar)
  },

  destroyed() {
    window.removeEventListener("scroll", this.alScrollOCerrar, true)
    window.removeEventListener("resize", this.alScrollOCerrar)
  },

  // Bug real (2026-09-10, catálogo Clientes, campo "Grupos"): este mismo
  // combo vive dentro de un contenedor `overflow-hidden` (el redondeado de
  // esquinas de la tarjeta, ver ficha_live.ex tab_datos/1) -- la lista
  // (`position: absolute`) quedaba recortada/invisible cada vez que el
  // campo caía cerca del borde inferior de esa tarjeta. Mismo tipo de bug
  // ya resuelto antes para el flyout del menú del engrane (menu.css) --
  // acá la solución es la misma idea pero calculada en JS: `position:
  // fixed` con coordenadas reales del input (getBoundingClientRect),
  // así la lista escapa de CUALQUIER ancestro con overflow, sin importar
  // en qué catálogo/posición esté este campo.
  posicionarLista() {
    const r = this.texto.getBoundingClientRect()
    Object.assign(this.lista.style, {
      position: "fixed",
      top: `${r.bottom + 2}px`,
      left: `${r.left}px`,
      width: `${r.width}px`,
      right: "auto",
      marginTop: "0",
      zIndex: "9999",
    })
  },

  // Referencia dependiente ("combo en cascada", ver
  // MetaSchemaContext.resolver_filtros/3): a diferencia del resto de este
  // hook (que nunca vuelve a tocar el servidor), `data-opciones` SÍ puede
  // cambiar entre renders para un campo con dependencias — cuando el
  // usuario elige/cambia su campo padre (ej. Estado), el server recalcula
  // las opciones del hijo (Municipio) y LiveView parchea este mismo <div>
  // (id estable, nunca se remonta). Sin esto, `this.opciones` quedaba
  // congelada con el dataset del primer mount para siempre.
  updated() {
    this.leerDataset()
    // Cualquier lista abierta mostraría opciones del padre anterior —
    // nunca queda colgada entre un cambio de padre y el siguiente F2/tecla.
    this.cerrar()

    // Red de seguridad: si el valor ya elegido dejó de estar entre las
    // opciones nuevas (el server debería haberlo limpiado él mismo, ver
    // MetaSchemaContext.limpiar_descendientes/3, pero un hook robusto no
    // depende solo de eso), se limpia acá también.
    if (this.hidden.value && !this.opciones.some((o) => String(o.id) === this.hidden.value)) {
      this.hidden.value = ""
      this.texto.value = ""
    }
  },

  leerDataset() {
    this.opciones = JSON.parse(this.el.dataset.opciones || "[]")
    this.deshabilitado = this.el.dataset.disabled === "true"
    this.texto.placeholder = this.deshabilitado && this.el.dataset.mensaje ? this.el.dataset.mensaje : "Escribí o F2 para buscar…"
  },

  abierta() {
    return !this.lista.classList.contains("hidden")
  },

  onKeydown(e) {
    if (e.key === "F2") {
      e.preventDefault()
      e.stopPropagation()
      this.abrir()
      return
    }

    if (!this.abierta()) return

    if (e.key === "ArrowDown") {
      e.preventDefault()
      e.stopPropagation()
      this.mover(1)
    } else if (e.key === "ArrowUp") {
      e.preventDefault()
      e.stopPropagation()
      this.mover(-1)
    } else if (e.key === "Enter") {
      e.preventDefault()
      e.stopPropagation()
      if (this.resaltado >= 0) this.elegir(this.filtradas[this.resaltado])
      else this.cerrar()
    } else if (e.key === "Escape") {
      e.preventDefault()
      e.stopPropagation()
      this.cerrar()
    }
  },

  onMousedownLista(e) {
    const li = e.target.closest("li[data-idx]")
    if (!li) return
    e.preventDefault()
    this.elegir(this.filtradas[parseInt(li.dataset.idx, 10)])
  },

  // F2 siempre muestra TODAS las opciones, ignorando lo que ya haya en el
  // input de texto -- si el campo ya tiene un valor elegido (ej. "LISTA
  // MAESTRA"), ese texto YA está en el input, y filtrar por él dejaba una
  // sola opción (la actual) en vez de dejar elegir otra (bug real,
  // reportado: "F2 no enlista más que el registro actual"). Tipear sigue
  // filtrando normal (ver el listener de "input" en mounted()), esto solo
  // afecta el estado inicial al abrir con F2.
  abrir() {
    this.filtrar("")
  },

  cerrar() {
    this.lista.classList.add("hidden")
    this.lista.innerHTML = ""
    this.resaltado = -1
  },

  filtrar(texto) {
    const q = texto.trim().toLowerCase()
    this.filtradas = q ? this.opciones.filter((o) => o.etiqueta.toLowerCase().includes(q)) : this.opciones
    this.resaltado = this.filtradas.length ? 0 : -1
    this.pintarLista()
  },

  pintarLista() {
    this.lista.innerHTML = this.filtradas.length
      ? this.filtradas
          .map(
            (o, i) =>
              `<li data-idx="${i}" role="option" class="px-2 py-1 cursor-pointer ${i === this.resaltado ? "bg-purple-100" : "hover:bg-gray-50"}">${escaparHtml(o.etiqueta)}</li>`
          )
          .join("")
      : `<li class="px-2 py-1 text-gray-400">Sin resultados</li>`
    this.posicionarLista()
    this.lista.classList.remove("hidden")
  },

  elegir(opcion) {
    if (!opcion) return
    this.hidden.value = opcion.id
    this.texto.value = opcion.etiqueta
    this.hidden.dispatchEvent(new Event("input", {bubbles: true}))
    this.cerrar()
    this.texto.focus()
  },
}
