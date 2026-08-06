// Comportamiento puramente de cliente del modal "Configurar relación"
// (BcMotorLive.modal_relacion/1) — buscar/filtrar, "Todos"/"Limpiar",
// contador de seleccionados, colapsar un grupo, e invertir el orden de
// "Dos datos combinados". Ninguno de estos toca el servidor: los
// checkboxes de las columnas 1/2 nunca tuvieron phx-change por campo
// (solo se leen al hacer submit de "Guardar relación"), así que filtrar
// mientras se tipea o tildar "Todos" no tiene por qué ir y volver a
// LiveView. Los <select>/radios de la columna 3 (modo de visualización)
// SÍ siguen yendo por phx-change="previsualizar_visualizacion" como
// siempre — este hook no toca esa parte, solo dispara el evento nativo
// cuando invierte el orden con el botón ⇄, para que LiveView se entere.

function columnaDe(el) {
  const lista = el.closest("[data-lista]")
  return lista ? lista.dataset.lista : null
}

export default {
  mounted() {
    this.el.querySelectorAll("[data-buscador]").forEach((input) => {
      input.addEventListener("input", () => this.aplicarBusqueda(input))
    })

    this.el.querySelectorAll("[data-todos]").forEach((btn) => {
      btn.addEventListener("click", () => this.seleccionarTodos(btn.dataset.todos))
    })

    this.el.querySelectorAll("[data-limpiar]").forEach((btn) => {
      btn.addEventListener("click", () => this.limpiarSeleccion(btn.dataset.limpiar))
    })

    this.el.querySelectorAll("[data-fila-input]").forEach((input) => {
      input.addEventListener("change", () => this.actualizarContador(columnaDe(input)))
    })

    this.el.querySelectorAll("[data-grupo-toggle]").forEach((btn) => {
      btn.addEventListener("click", () => this.alternarGrupo(btn))
    })

    const swap = this.el.querySelector("[data-swap-visualizacion]")
    if (swap) swap.addEventListener("click", () => this.invertirOrden())

    this.el.querySelectorAll("[data-contador]").forEach((el) => this.actualizarContador(el.dataset.contador))
  },

  aplicarBusqueda(input) {
    const columna = input.dataset.buscador
    const query = input.value.trim().toLowerCase()
    const lista = this.el.querySelector(`[data-lista="${columna}"]`)
    if (!lista) return

    let visibles = 0

    lista.querySelectorAll("[data-grupo]").forEach((grupo) => {
      let grupoVisible = false

      grupo.querySelectorAll("[data-fila]").forEach((fila) => {
        const coincide = !query || fila.dataset.buscable.includes(query)
        fila.style.display = coincide ? "" : "none"
        if (coincide) {
          grupoVisible = true
          visibles++
        }
      })

      grupo.style.display = grupoVisible ? "" : "none"
    })

    const vacio = this.el.querySelector(`[data-vacio="${columna}"]`)
    if (vacio) vacio.classList.toggle("hidden", visibles !== 0 || query === "")
  },

  seleccionarTodos(columna) {
    const lista = this.el.querySelector(`[data-lista="${columna}"]`)
    if (!lista) return

    lista.querySelectorAll("[data-fila]").forEach((fila) => {
      if (fila.style.display !== "none") {
        const input = fila.querySelector("[data-fila-input]")
        if (input) input.checked = true
      }
    })

    this.actualizarContador(columna)
  },

  limpiarSeleccion(columna) {
    const lista = this.el.querySelector(`[data-lista="${columna}"]`)
    if (!lista) return

    lista.querySelectorAll("[data-fila-input]").forEach((input) => {
      input.checked = false
    })

    this.actualizarContador(columna)
  },

  actualizarContador(columna) {
    if (!columna) return
    const lista = this.el.querySelector(`[data-lista="${columna}"]`)
    const contador = this.el.querySelector(`[data-contador="${columna}"]`)
    if (!lista || !contador) return

    const inputs = lista.querySelectorAll("[data-fila-input]")
    const total = inputs.length
    const marcados = Array.from(inputs).filter((i) => i.checked).length
    contador.textContent = `${marcados} de ${total} seleccionados`
  },

  alternarGrupo(btn) {
    const grupo = btn.closest("[data-grupo]")
    const body = grupo && grupo.querySelector("[data-grupo-body]")
    const icono = btn.querySelector("[data-grupo-icono]")
    if (!body) return

    const colapsado = body.style.display === "none"
    body.style.display = colapsado ? "" : "none"
    if (icono) icono.textContent = colapsado ? "expand_more" : "chevron_right"
  },

  // "Dos datos combinados": swap del valor de los dos <select> (código ↔
  // descripción) para no obligar a dos radios separados ("Nombre + RFC" /
  // "RFC + Nombre") — dispara "change" en ambos para que LiveView
  // reciba el nuevo orden y recalcule la vista previa (phx-change en el
  // <form> que envuelve todo).
  invertirOrden() {
    const codigo = this.el.querySelector('select[name="campo_visualizacion[campo_codigo]"]')
    const descripcion = this.el.querySelector('select[name="campo_visualizacion[campo_descripcion]"]')
    if (!codigo || !descripcion) return

    const temp = codigo.value
    codigo.value = descripcion.value
    descripcion.value = temp

    codigo.dispatchEvent(new Event("change", {bubbles: true}))
    descripcion.dispatchEvent(new Event("change", {bubbles: true}))
  },
}
