// GridConstructor — arrastrar y soltar sobre el editor de grid 2D del
// Constructor de plantillas (ver PlantillaConstructorLive.grid_editor/1).
// Sortable.js (ListaOrdenable, ver app.js) es para listas 1D — acá hace
// falta soltar en una celda (fila, columna) EXACTA con feedback de
// ocupada/libre, así que es Drag and Drop nativo del navegador
// (dragstart/dragover/drop), mismo espíritu que ListaOrdenable: este hook
// SOLO da feedback visual y arma el pushEvent — la verdad (¿cabe ahí?) la
// decide siempre el servidor (MetaPlantillas.colocar_en_celda/5,
// mover_celda/4), acá nunca se muta nada a mano.
//
// Origen del arrastre (ver data-origen en grid_editor/1):
//   - "paleta": un botón de la paleta reducida (@tipos_celda/@tipos_campo
//     en modo grid) — trae data-tipo o data-filtro.
//   - "celda": un chip ya colocado (mover uno existente) — trae data-nodo-id.
//
// El hook vive en el contenedor raíz de la grilla (id="gc-grid"), montado
// de nuevo cada vez que se abre un grid distinto (LiveView destruye/vuelve
// a montar el hook porque cambia el id del nodo padre en el árbol de
// PlantillaConstructorLive) — por eso el listener de la paleta se cuelga a
// nivel `document` (los botones de paleta viven AFUERA de este contenedor,
// en la columna izquierda) y se limpia en destroyed().
export default {
  mounted() {
    this.alDragStartPaleta = (e) => this.onDragStartPaleta(e)
    document.addEventListener("dragstart", this.alDragStartPaleta)

    this.el.addEventListener("dragstart", (e) => this.onDragStartCelda(e))
    this.el.addEventListener("dragover", (e) => this.onDragOver(e))
    this.el.addEventListener("dragleave", (e) => this.onDragLeave(e))
    this.el.addEventListener("drop", (e) => this.onDrop(e))
  },

  destroyed() {
    document.removeEventListener("dragstart", this.alDragStartPaleta)
  },

  onDragStartPaleta(e) {
    const origen = e.target.closest('[data-origen="paleta"]')
    if (!origen) return
    const payload = {origen: "paleta"}
    if (origen.dataset.tipo) payload.tipo = origen.dataset.tipo
    if (origen.dataset.filtro) payload.filtro = origen.dataset.filtro
    e.dataTransfer.setData("text/plain", JSON.stringify(payload))
    e.dataTransfer.effectAllowed = "copy"
  },

  onDragStartCelda(e) {
    const origen = e.target.closest('[data-origen="celda"]')
    if (!origen) return
    e.dataTransfer.setData("text/plain", JSON.stringify({origen: "celda", nodo_id: origen.dataset.nodoId}))
    e.dataTransfer.effectAllowed = "move"
  },

  celdaDestino(e) {
    return e.target.closest("[data-fila][data-columna]")
  },

  onDragOver(e) {
    const celda = this.celdaDestino(e)
    if (!celda) return
    e.preventDefault()
    celda.classList.remove("gc-drop-valido", "gc-drop-invalido")
    celda.classList.add(celda.dataset.ocupada === "true" ? "gc-drop-invalido" : "gc-drop-valido")
  },

  onDragLeave(e) {
    const celda = this.celdaDestino(e)
    if (celda) celda.classList.remove("gc-drop-valido", "gc-drop-invalido")
  },

  onDrop(e) {
    const celda = this.celdaDestino(e)
    if (!celda) return
    e.preventDefault()
    celda.classList.remove("gc-drop-valido", "gc-drop-invalido")

    let payload
    try {
      payload = JSON.parse(e.dataTransfer.getData("text/plain") || "{}")
    } catch {
      return
    }

    this.pushEvent("grid_soltar", {fila: celda.dataset.fila, columna: celda.dataset.columna, ...payload})
  },
}
