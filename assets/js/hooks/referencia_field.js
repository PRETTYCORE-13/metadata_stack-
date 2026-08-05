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
    this.opciones = JSON.parse(this.el.dataset.opciones || "[]")
    this.hidden = this.el.querySelector("[data-campo-hidden]")
    this.texto = this.el.querySelector("[data-campo-texto]")
    this.lista = this.el.querySelector("[data-campo-lista]")
    this.resaltado = -1
    this.filtradas = []

    this.texto.addEventListener("keydown", (e) => this.onKeydown(e))
    this.texto.addEventListener("input", () => this.filtrar(this.texto.value))
    this.texto.addEventListener("blur", () => this.cerrar())
    this.lista.addEventListener("mousedown", (e) => this.onMousedownLista(e))
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

  abrir() {
    this.filtrar(this.texto.value)
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
