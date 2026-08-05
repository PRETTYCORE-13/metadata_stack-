// RenglonForm — captura continua tipo spreadsheet para
// FichaLive.formulario_renglon/1 (catálogos maestro-detalle). Los datos de
// la línea ya viajan campo a campo por el phx-change de siempre
// ("detalle_form_cambiar" -> "grid_actualizar_fila", ver grid_editable.js);
// este hook solo agrega los atajos de teclado — nunca dueño de datos.
//
// - Enter en un campo intermedio: igual que Tab, avanza al siguiente campo
//   VISIBLE (los campos dentro de un <details> cerrado no cuentan — el
//   navegador ya los excluye del tabIndex natural, así que ni hace falta
//   una lista hardcodeada de "primer grupo").
// - Enter en el ÚLTIMO campo visible: confirma la línea si es válida.
//   "Válida" se apoya en la validación nativa del HTML (required/type=/
//   maxlength ya están en cada input, ver CampoInputComponents) — si
//   checkValidity() da falso, reportValidity() muestra el globo nativo del
//   navegador y no pasa nada más; si da true, se reusa el evento
//   "detalle_nueva_linea" (mismo que antes disparaba el botón "+"): el
//   servidor deja el formulario en blanco y pide una fila nueva a la
//   tabla.
// - Escape: "detalle_cancelar_linea" — una línea nueva sin persistir se
//   descarta entera; un renglón ya existente revierte sus campos tocados.
// - "detalle_enfocar_primero": señal explícita del servidor (después de
//   confirmar o cancelar) para devolver el foco al primer campo — nunca se
//   infiere de updated() en general, eso podría robarle el foco al usuario
//   en medio de otra edición.
//
// Un combobox de referencia (ver referencia_field.js) puede estar anidado
// adentro de este <form> — cuando su propia lista de sugerencias está
// abierta, intercepta Enter/Escape/F2 con stopPropagation() antes de que
// lleguen acá, mismo patrón que un diálogo atrapando Escape.
const SELECTOR_CAMPOS = "input:not([type=hidden]), select, textarea"

// Campos deshabilitados (renglón ya persistido, campo fuera de
// campos_editables de la transición "guardar" — ver
// FichaLive.campo_detalle_editable?/3) quedan afuera: ni Tab/Enter los
// visitan, ni checkValidity() los exige (un <input disabled> ya está
// fuera de la validación nativa por spec, así que esto es solo para que
// la navegación por teclado no se detenga en un campo que no se puede
// tocar).
function camposVisibles(form) {
  return Array.from(form.querySelectorAll(SELECTOR_CAMPOS)).filter((el) => el.offsetParent !== null && !el.disabled)
}

export default {
  mounted() {
    this.catalogo = this.el.dataset.catalogo
    this.alTecla = (e) => this.onKeydown(e)
    this.el.addEventListener("keydown", this.alTecla)

    this.handleEvent("detalle_enfocar_primero", ({catalogo}) => {
      if (catalogo !== this.catalogo) return
      this.enfocarPrimero()
    })

    this.enfocarPrimero()
  },

  destroyed() {
    this.el.removeEventListener("keydown", this.alTecla)
  },

  enfocarPrimero() {
    const campos = camposVisibles(this.el)
    if (campos[0]) campos[0].focus()
  },

  onKeydown(e) {
    if (e.key === "Enter") {
      e.preventDefault()
      const campos = camposVisibles(this.el)
      const idx = campos.indexOf(e.target)
      if (idx === -1) return

      if (idx < campos.length - 1) {
        campos[idx + 1].focus()
        return
      }

      if (!this.el.checkValidity()) {
        this.el.reportValidity()
        return
      }

      this.pushEvent("detalle_nueva_linea", {catalogo: this.catalogo})
      return
    }

    if (e.key === "Escape") {
      e.preventDefault()
      this.pushEvent("detalle_cancelar_linea", {catalogo: this.catalogo})
    }
  },
}
