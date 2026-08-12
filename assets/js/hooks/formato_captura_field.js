// FormatoCapturaField — máscara posicional para campos "string" con
// `formato_captura` habilitado (Teléfono/CP/RFC/Fecha libre/Personalizada,
// ver MetaSchemaContext.validar_formato_captura/2). A diferencia de
// ReferenciaField, acá no hay par hidden/visible: el propio <input> es el
// valor real que se somete, así que el hook reformatea `el.value` in-place.
//
// `data-estricto="true"` (default): en cada tecla, reconstruye el valor
// insertando los literales del patrón y descartando cualquier carácter que
// no calce con la clase de su posición (A=letra, 9=número, *=cualquiera).
// `data-estricto="false"`: no toca nada mientras se tipea — el patrón se
// valida solo al guardar (MetaSchemaContext.validar_formato_captura/2), acá
// no hay nada que hacer.
//
// `data-guardar-formato="false"`: al perder foco, reduce el valor a solo
// los caracteres de los "slots" (sin los literales del patrón) antes de que
// el próximo phx-change lo vea — así el catálogo persiste "5512345678" en
// vez de "(551) 234-5678".
function calzaClase(pc, ch) {
  if (pc === "A") return /[a-zA-Z]/.test(ch)
  if (pc === "9") return /[0-9]/.test(ch)
  return true
}

function aplicarMascara(patron, entrada) {
  if (!patron) return entrada

  let conFormato = ""
  let ei = 0

  for (let pi = 0; pi < patron.length; pi++) {
    const pc = patron[pi]
    const esSlot = pc === "A" || pc === "9" || pc === "*"

    if (ei >= entrada.length) break

    if (esSlot) {
      while (ei < entrada.length && !calzaClase(pc, entrada[ei])) ei++
      if (ei >= entrada.length) break
      conFormato += pc === "A" ? entrada[ei].toUpperCase() : entrada[ei]
      ei++
    } else {
      conFormato += pc
      if (entrada[ei] === pc) ei++
    }
  }

  return conFormato
}

function soloDatos(patron, entrada) {
  let datos = ""
  let ei = 0

  for (let pi = 0; pi < patron.length; pi++) {
    const pc = patron[pi]
    const esSlot = pc === "A" || pc === "9" || pc === "*"

    if (ei >= entrada.length) break

    if (esSlot) {
      while (ei < entrada.length && !calzaClase(pc, entrada[ei])) ei++
      if (ei >= entrada.length) break
      datos += pc === "A" ? entrada[ei].toUpperCase() : entrada[ei]
      ei++
    } else {
      if (entrada[ei] === pc) ei++
    }
  }

  return datos
}

export default {
  mounted() {
    this.leerDataset()
    this.el.addEventListener("input", () => this.onInput())
    this.el.addEventListener("blur", () => this.onBlur())
  },

  updated() {
    this.leerDataset()
  },

  leerDataset() {
    this.patron = this.el.dataset.patron || ""
    this.estricto = this.el.dataset.estricto !== "false"
    this.guardarFormato = this.el.dataset.guardarFormato !== "false"
  },

  onInput() {
    if (!this.estricto || !this.patron) return
    const nuevo = aplicarMascara(this.patron, this.el.value)
    if (nuevo !== this.el.value) this.el.value = nuevo
  },

  onBlur() {
    if (this.guardarFormato || !this.patron || !this.el.value) return
    const nuevo = soloDatos(this.patron, this.el.value)
    if (nuevo !== this.el.value) {
      this.el.value = nuevo
      this.el.dispatchEvent(new Event("input", {bubbles: true}))
    }
  },
}
