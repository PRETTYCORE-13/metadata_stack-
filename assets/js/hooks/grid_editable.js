// Grid Editable Empresarial — motor de captura tipo Excel para renglones de
// catálogos maestro-detalle. El estado real de la grilla vive acá
// (this.rows), separado de cómo se pinta (render()) — teclado, pegado y
// validación operan siempre sobre this.rows/índices, nunca sobre el DOM
// directo, así la Fase 2 (virtualización, ver más abajo) solo reemplaza el
// CUERPO de render() sin tocar el resto.
//
// El elemento raíz tiene phx-update="ignore" (ver GridEditableComponents) —
// LiveView nunca vuelve a tocar este <tbody> después del primer render, este
// hook es el único dueño de ese DOM. Actualizaciones del servidor después de
// eso (guardar, transición de un renglón) llegan por push_event, nunca por
// un re-render de LiveView.
//
// Fase 2 — virtualización: con pocas filas (<= VIRTUALIZAR_DESDE) se pinta
// todo el <tbody> de una, igual que la Fase 1 (sin altura fija, sin scroll
// propio — la tabla crece con el contenido, como cualquier tabla HTML de
// siempre). Por arriba de ese umbral, el contenedor `.ge-scroll` pasa a
// tener altura fija + `overflow-y: auto`, y el <tbody> solo materializa la
// ventana de filas visible (+ buffer) — el resto del alto se simula con dos
// filas espaciadoras (altura = filas fuera de la ventana × ROW_H), técnica
// estándar para virtualizar sobre un <table> real sin pelearse con
// `position: absolute` en `<tr>` (que las tablas no soportan bien). Nunca
// se crean/destruyen más de ~30-40 nodos `<tr>` a la vez, sin importar si
// hay 100 o 10.000 filas cargadas en this.rows.
const ROW_H = 33
const VIRTUALIZAR_DESDE = 50
const FILAS_EN_VENTANA = 15
const BUFFER_FILAS = 8

// Fase 3 (asistencia con IA, Nivel A) — nada de esto llama al servidor ni
// necesita infraestructura nueva: autocompletar por columna con lo que ya
// se tipeó en ESTA sesión de captura (vía <datalist> nativo del navegador,
// se actualiza al salir de cada celda, no en cada tecla) y aviso suave de
// filas que podrían ser duplicadas (nunca bloquea guardar — hay duplicados
// legítimos de verdad). El Nivel B (aprendizaje entre sesiones, correcciones
// automáticas con un modelo real) sigue explícitamente fuera de alcance —
// ver docs/catalogo-maestro-detalle-requerimientos.md Fase 7.
const MAX_VALORES_RECIENTES = 20

const TIPOS_NUMERICOS = ["integer", "decimal"]

function celdaVacia(valor) {
  return valor === undefined || valor === null || valor === "" || valor === "false"
}

function filaVacia(values, columns) {
  return columns.every((c) => celdaVacia(values[c.campo]))
}

function escaparHtml(valor) {
  return String(valor).replace(/[&<>"']/g, (c) => ({"&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;"}[c]))
}

// Fase 2 (virtualización): qué rango [inicio, fin) de filas materializar en
// el DOM dado el scroll actual — la única cuenta con riesgo real de bug
// (off-by-one, ventana vacía, etc.), separada de render() para poder
// probarla sin DOM (ver assets/js/hooks/__tests__/grid_editable.test.mjs).
// `total` ya viene recortado a lo que hay de verdad (this.filasVisibles().length).
export function calcularVentana(scrollTop, altoContenedor, total) {
  const inicio = Math.max(0, Math.floor(scrollTop / ROW_H) - BUFFER_FILAS)
  const fin = Math.min(total, Math.ceil((scrollTop + altoContenedor) / ROW_H) + BUFFER_FILAS)
  return {inicio, fin: Math.max(inicio, fin)}
}

// Formato estándar de pegado de Excel/Sheets: filas separadas por salto de
// línea, columnas por tab. Se descarta una última línea vacía (lo que deja
// un "\n" final del portapapeles, muy común). Exportado para poder probarlo
// sin DOM (ver assets/js/hooks/__tests__/grid_editable.test.mjs).
export function parsePaste(texto) {
  const lineas = texto.replace(/\r\n/g, "\n").replace(/\r/g, "\n").split("\n")
  if (lineas.length > 1 && lineas[lineas.length - 1] === "") lineas.pop()
  return lineas.map((linea) => linea.split("\t"))
}

// nueva/modificada/error/sin_cambios se derivan, nunca se guardan aparte —
// así no hay forma de que queden desincronizados de los datos reales.
export function computeStatus(row) {
  if (row.marcadaEliminar) return "eliminar"
  if (row.errors && Object.keys(row.errors).some((k) => (row.errors[k] || []).length > 0)) return "error"
  if (row.renglonId == null) return "nueva"
  if (row.dirty && row.dirty.size > 0) return "modificada"
  return "sin_cambios"
}

// Lista de valores recientes de UNA columna, más reciente primero, sin
// repetidos, recortada a `max` — la sugerencia "el último valor tipeado"
// (estilo Excel) es simplemente el primero de esta lista; el resto alimenta
// el <datalist> de esa columna. Pura y exportada para probarla sin DOM.
export function actualizarValoresRecientes(valores, valorNuevo, max = MAX_VALORES_RECIENTES) {
  const limpio = (valorNuevo || "").trim()
  if (!limpio) return valores
  return [limpio, ...valores.filter((v) => v !== limpio)].slice(0, max)
}

// Firma de una fila para detectar posibles duplicados: valores recortados y
// en minúscula (case-insensitive) de las columnas de la grilla — barato y
// suficiente para "podría ser la misma fila dos veces", no pretende ser una
// comparación semántica.
export function firmaFila(values, columns) {
  return columns.map((c) => String(values[c.campo] ?? "").trim().toLowerCase()).join("")
}

// Índices (dentro de `filas`) que comparten firma con al menos otra fila no
// vacía. Aviso suave — nunca bloquea nada, puede haber duplicados legítimos
// (dos clientes distintos con el mismo nombre, por ejemplo).
export function detectarDuplicados(filas, columns) {
  const vistos = new Map()
  const duplicados = new Set()

  filas.forEach((fila, i) => {
    if (filaVacia(fila.values, columns)) return
    const firma = firmaFila(fila.values, columns)
    if (vistos.has(firma)) {
      duplicados.add(i)
      duplicados.add(vistos.get(firma))
    } else {
      vistos.set(firma, i)
    }
  })

  return duplicados
}

// Validación síncrona, solo con lo que ya existe en schema_context_properties
// (tipo/opcional/longitud/valores) — cubre requerido, tipo, y enum. Lo que
// esto no puede ver (existencia de FK, reglas del changeset) viaja al
// servidor por separado (ver programarValidacionServidor).
function validarCelda(valor, columna) {
  const vacio = celdaVacia(valor)

  if (!columna.opcional && vacio) return ["obligatorio"]
  if (vacio) return []

  if (TIPOS_NUMERICOS.includes(columna.tipo)) {
    const regex = columna.tipo === "integer" ? /^-?\d+$/ : /^-?\d+(\.\d+)?$/
    if (!regex.test(String(valor).trim())) return ["debe ser numérico"]
  } else if (columna.tipo === "date") {
    if (Number.isNaN(Date.parse(valor))) return ["fecha inválida"]
  } else if (columna.tipo === "enum" && Array.isArray(columna.valores)) {
    if (!columna.valores.includes(valor)) return ["valor no permitido"]
  } else if (columna.longitud && String(valor).length > columna.longitud) {
    return [`máximo ${columna.longitud} caracteres`]
  }

  return []
}

let contadorClientId = 0
function nuevoClientId() {
  contadorClientId += 1
  return `n${Date.now()}-${contadorClientId}`
}

function filaNueva() {
  return {clientId: nuevoClientId(), renglonId: null, estado: null, values: {}, original: {}, dirty: new Set(), errors: {}}
}

function filaDesdeServidor(f) {
  return {
    clientId: nuevoClientId(),
    renglonId: f.renglon_id,
    estado: f.estado,
    values: {...f.values},
    original: {...f.values},
    dirty: new Set(),
    errors: {},
    marcadaEliminar: false,
  }
}

export default {
  mounted() {
    this.catalogo = this.el.dataset.catalogo
    this.columns = JSON.parse(this.el.dataset.columnas || "[]")
    this.transiciones = JSON.parse(this.el.dataset.transiciones || "[]")
    this.rows = JSON.parse(this.el.dataset.filas || "[]").map(filaDesdeServidor)
    this.validarTimers = {}
    this.syncTimer = null
    this.tbody = this.el.querySelector("tbody")
    this.scrollBox = this.el.querySelector(".ge-scroll")
    this.virtualizando = false
    this.ventanaInicio = null
    this.ventanaFin = null
    this.scrollRaf = null
    // Layout 2 columnas (formulario izq. + grilla der.): clientId de la
    // fila "activa" — el formulario de FichaLive.formulario_renglon/1
    // muestra/edita SIEMPRE esta fila (nunca un modal). null = ninguna
    // seleccionada todavía.
    this.filaSeleccionadaClientId = null

    // Fase 3, Nivel A: arranca con lo que ya está persistido (si el
    // catálogo ya tenía renglones) como base de "valores recientes" — no
    // hace falta esperar a que el usuario tipee algo en esta sesión para
    // que la sugerencia sirva de algo.
    this.valoresRecientes = {}
    this.rows.forEach((fila) => {
      this.columns.forEach((col) => {
        this.valoresRecientes[col.campo] = actualizarValoresRecientes(this.valoresRecientes[col.campo] || [], fila.values[col.campo])
      })
    })
    this.crearDatalists()

    this.el.addEventListener("keydown", (e) => this.alTecla(e))
    this.el.addEventListener("paste", (e) => this.alPegar(e))
    this.el.addEventListener("input", (e) => this.alEscribir(e))
    this.el.addEventListener("click", (e) => this.alClicAccion(e))
    // "Aprende" el valor recién tipeado al SALIR de la celda, no en cada
    // tecla — si no, un valor a medio escribir ("Ju", "Jua", "Juan")
    // ensuciaría la lista de sugerencias con basura intermedia.
    this.el.addEventListener("focusout", (e) => this.alSalirCelda(e))
    // Selección de fila (layout 2 columnas): CUALQUIER forma de llegar el
    // foco a una celda (clic, Tab, flechas, enfocarCelda programático)
    // pasa por acá — un solo lugar, en vez de repetir la lógica en cada
    // manejador de teclado/clic.
    this.el.addEventListener("focusin", (e) => this.alEnfocarCelda(e))

    // Throttleado con requestAnimationFrame — el scroll dispara muchos
    // eventos por segundo, pero repintar la ventana en cada uno es
    // trabajo de sobra; alcanza con recalcular una vez por frame.
    this.scrollBox.addEventListener("scroll", () => {
      if (!this.virtualizando || this.scrollRaf) return
      this.scrollRaf = requestAnimationFrame(() => {
        this.scrollRaf = null
        this.actualizarVentana()
      })
    })

    // Captura, no burbuja: tiene que dispararse ANTES de que el propio
    // manejador de phx-click="guardar" de LiveView mande el evento
    // "guardar" al servidor, para que grid_sync llegue primero por el mismo
    // socket (los eventos de un mismo cliente se procesan en el orden en
    // que se mandan) — así guardar_edicion/1 nunca ve datos de la grilla
    // desactualizados. La fase de captura del DOM siempre corre antes que
    // cualquier listener en fase de burbuja, sin importar el orden de
    // registro, así que esto es determinístico, no una carrera.
    this.botonGuardar = document.querySelector('[phx-click="guardar"]')
    this.alGuardarClick = () => this.sincronizarAhora()
    if (this.botonGuardar) this.botonGuardar.addEventListener("click", this.alGuardarClick, true)

    this.handleEvent("grid_errores_fila", ({catalogo, client_id, errores}) => {
      if (catalogo !== this.catalogo) return
      const fila = this.rows.find((r) => r.clientId === client_id)
      if (!fila) return
      fila.errors = errores || {}
      this.render()
    })

    // El servidor manda esto después de una transición de renglón exitosa
    // (ver handle_event("renglon_transicion", ...)) — reemplaza las filas
    // existentes por el estado real recién leído de la base, descartando
    // cualquier edición sin sincronizar de ESTE catálogo (mismo criterio
    // que "actualizar ficha" en el resto de la pantalla).
    this.handleEvent("grid_recargar", ({catalogo, filas, transiciones}) => {
      if (catalogo !== this.catalogo) return
      this.rows = (filas || []).map(filaDesdeServidor)
      if (transiciones) this.transiciones = transiciones
      this.filaSeleccionadaClientId = null
      // Dataset nuevo — la ventana anterior ya no tiene sentido, se
      // recalcula de cero en el próximo render() según el alto real del
      // contenedor en ese momento.
      this.ventanaInicio = null
      this.ventanaFin = null
      this.render()
    })

    // --- Layout 2 columnas: eventos del formulario izquierdo -------------

    // El formulario editó un campo de la fila seleccionada — se aplica acá
    // exactamente igual que si se hubiese tipeado en la celda (misma
    // validación/sync debounced), así las dos vistas de la fila nunca se
    // desincronizan.
    this.handleEvent("grid_actualizar_fila", ({catalogo, client_id, valores}) => {
      if (catalogo !== this.catalogo) return
      const idx = this.rows.findIndex((r) => r.clientId === client_id)
      if (idx === -1) return
      Object.entries(valores).forEach(([campo, valor]) => this.setCelda(idx, campo, valor))
      this.render()
      this.programarValidacionServidor(idx)
      this.programarSync()
    })

    // "+ Nueva línea" del formulario: crea una fila real en blanco (no la
    // fantasma efímera de filasVisibles/2, que cambia de clientId en cada
    // llamada) y la enfoca — enfocarCelda dispara "focusin", que reporta
    // la selección real (con su clientId verdadero) de vuelta al servidor.
    this.handleEvent("grid_nueva_fila", ({catalogo}) => {
      if (catalogo !== this.catalogo) return
      const idx = this.rows.length
      this.asegurarFila(idx)
      this.render()
      this.enfocarCelda(idx, 0)
    })

    // "Eliminar línea" del formulario — solo para filas TODAVÍA sin
    // renglon_id (mismo criterio que borrarFilaNueva/ge-quitar; el
    // servidor ya lo garantiza del otro lado, esto es defensa en
    // profundidad, nunca borra un renglón persistido).
    this.handleEvent("grid_quitar_fila", ({catalogo, client_id}) => {
      if (catalogo !== this.catalogo) return
      const idx = this.rows.findIndex((r) => r.clientId === client_id)
      if (idx === -1 || this.rows[idx].renglonId != null) return
      this.rows.splice(idx, 1)
      if (this.filaSeleccionadaClientId === client_id) this.filaSeleccionadaClientId = null
      this.render()
      this.programarSync()
    })

    // Navegación anterior/siguiente del formulario, entre renglones YA
    // persistidos — el servidor ya resolvió cuál es y actualizó el
    // formulario con sus valores; acá solo hace falta resaltar/enfocar esa
    // fila (enfocarCelda ya sabe traerla a la vista si está virtualizada).
    this.handleEvent("grid_resaltar_fila", ({catalogo, renglon_id}) => {
      if (catalogo !== this.catalogo) return
      const idx = this.filasVisibles().findIndex((f) => f.renglonId === renglon_id)
      if (idx === -1) return
      this.enfocarCelda(idx, 0)
    })

    this.render()
  },

  destroyed() {
    if (this.botonGuardar) this.botonGuardar.removeEventListener("click", this.alGuardarClick, true)
    clearTimeout(this.syncTimer)
    Object.values(this.validarTimers).forEach(clearTimeout)
  },

  // --- Filas a mostrar: this.rows + una fantasma en blanco al final ------
  // La fantasma NO vive en this.rows hasta que se empieza a tipear en ella
  // (ver alEscribir/asegurarFila) — así this.rows nunca acumula filas
  // vacías, ni una por cada tecla.
  filasVisibles() {
    const ultima = this.rows[this.rows.length - 1]
    if (!ultima || !filaVacia(ultima.values, this.columns)) return [...this.rows, filaNueva()]
    return this.rows
  },

  asegurarFila(rowIdx) {
    while (this.rows.length <= rowIdx) this.rows.push(filaNueva())
  },

  setCelda(rowIdx, campo, valor) {
    this.asegurarFila(rowIdx)
    const fila = this.rows[rowIdx]
    fila.values[campo] = valor
    if (fila.renglonId != null && valor !== fila.original[campo]) fila.dirty.add(campo)
    const col = this.columns.find((c) => c.campo === campo)
    fila.errors[campo] = col ? validarCelda(valor, col) : []
  },

  // --- Fase 3, Nivel A: autocompletar por columna (<datalist> nativo) ------
  // Un <datalist> por columna, fuera del <tbody> (no lo toca render()) —
  // cada input de esa columna lo referencia con list="...", el navegador
  // se encarga de mostrar el desplegable de sugerencias solo.
  crearDatalists() {
    this.datalistIds = {}
    this.columns.forEach((col) => {
      const id = `${this.el.id}-dl-${col.campo}`
      this.datalistIds[col.campo] = id
      const datalist = document.createElement("datalist")
      datalist.id = id
      this.el.appendChild(datalist)
      this.actualizarDatalist(col.campo)
    })
  },

  actualizarDatalist(campo) {
    const id = this.datalistIds && this.datalistIds[campo]
    const datalist = id && document.getElementById(id)
    if (!datalist) return
    const valores = this.valoresRecientes[campo] || []
    datalist.innerHTML = valores.map((v) => `<option value="${escaparHtml(v)}"></option>`).join("")
  },

  alSalirCelda(e) {
    const input = e.target.closest(".ge-input")
    if (!input || !input.value.trim()) return
    const campo = input.dataset.campo
    this.valoresRecientes[campo] = actualizarValoresRecientes(this.valoresRecientes[campo] || [], input.value)
    this.actualizarDatalist(campo)
  },

  // --- Layout 2 columnas: selección de fila ---------------------------------
  alEnfocarCelda(e) {
    const input = e.target.closest(".ge-input")
    if (!input) return
    this.seleccionarFila(parseInt(input.dataset.row, 10))
  },

  // Promueve la fila a "real" (asegurarFila — si era la fantasma efímera,
  // ahora vive en this.rows con un clientId estable) y le avisa al
  // formulario de FichaLive cuál es el renglón activo, con los valores que
  // la grilla YA tiene en memoria (incluye tipeo todavía sin sincronizar).
  seleccionarFila(rowIdx) {
    this.asegurarFila(rowIdx)
    const fila = this.rows[rowIdx]
    if (!fila || fila.clientId === this.filaSeleccionadaClientId) return
    this.filaSeleccionadaClientId = fila.clientId
    this.render()
    this.pushEvent("detalle_seleccionar_fila", {
      catalogo: this.catalogo,
      client_id: fila.clientId,
      renglon_id: fila.renglonId,
      valores: fila.values,
    })
  },

  render() {
    const filas = this.filasVisibles()
    const total = filas.length
    this.virtualizando = total > VIRTUALIZAR_DESDE
    this.actualizarModoScroll()
    // Fase 3, Nivel A: aviso suave de posibles duplicados — se recalcula en
    // cada render, es una comparación barata incluso con miles de filas.
    this.duplicados = detectarDuplicados(filas, this.columns)

    if (!this.virtualizando) {
      this.tbody.innerHTML = filas.map((fila, i) => this.filaHtml(fila, i, false, this.duplicados.has(i))).join("")
      return
    }

    if (this.ventanaInicio == null) {
      const inicial = calcularVentana(this.scrollBox.scrollTop, this.scrollBox.clientHeight, total)
      this.ventanaInicio = inicial.inicio
      this.ventanaFin = inicial.fin
    }

    const inicio = Math.max(0, Math.min(this.ventanaInicio, total))
    const fin = Math.max(inicio, Math.min(this.ventanaFin, total))
    const colspan = this.columns.length + 3
    const altoArriba = inicio * ROW_H
    const altoAbajo = (total - fin) * ROW_H

    const filasHtml = filas
      .slice(inicio, fin)
      .map((fila, idx) => this.filaHtml(fila, inicio + idx, true, this.duplicados.has(inicio + idx)))
      .join("")

    this.tbody.innerHTML =
      `<tr aria-hidden="true" style="height:${altoArriba}px"><td colspan="${colspan}" style="padding:0;border:0"></td></tr>` +
      filasHtml +
      `<tr aria-hidden="true" style="height:${altoAbajo}px"><td colspan="${colspan}" style="padding:0;border:0"></td></tr>`
  },

  // Fija la altura del contenedor de scroll solo cuando hay filas de sobra
  // como para justificarlo — con pocas filas la tabla se comporta como
  // cualquier tabla HTML normal, sin caja de scroll propia (Fase 1, sin
  // cambios de comportamiento para el caso común).
  actualizarModoScroll() {
    if (this.virtualizando) {
      this.scrollBox.style.maxHeight = `${ROW_H * FILAS_EN_VENTANA}px`
      this.scrollBox.style.overflowY = "auto"
    } else {
      this.scrollBox.style.maxHeight = ""
      this.scrollBox.style.overflowY = ""
    }
  },

  // Recalcula qué ventana de filas materializar según el scroll actual y
  // vuelve a pintar SOLO si la ventana realmente cambió (evita re-renders
  // de sobra en scrolls chiquitos que no cruzan el buffer).
  actualizarVentana() {
    const total = this.filasVisibles().length
    const {inicio, fin} = calcularVentana(this.scrollBox.scrollTop, this.scrollBox.clientHeight, total)

    if (inicio === this.ventanaInicio && fin === this.ventanaFin) return
    this.ventanaInicio = inicio
    this.ventanaFin = fin
    this.render()
  },

  filaHtml(fila, i, alturaFija, esDuplicado) {
    const status = computeStatus(fila)

    const filaClases = {
      nueva: "bg-green-50/40 border-l-2 border-l-green-400",
      modificada: "bg-amber-50/40 border-l-2 border-l-amber-400",
      error: "bg-red-50/60 border-l-2 border-l-red-500",
      eliminar: "bg-gray-100/70 border-l-2 border-l-gray-400",
      sin_cambios: "border-l-2 border-l-transparent",
    }[status]

    const puntoClase = {
      nueva: "bg-green-500",
      modificada: "bg-amber-500",
      error: "bg-red-500",
      eliminar: "bg-gray-400",
      sin_cambios: "bg-transparent",
    }[status]

    // Layout 2 columnas: la fila que el formulario de la izquierda está
    // mostrando/editando ahora mismo — un ring en vez de tocar el fondo,
    // así convive sin pelearse con los colores de status de arriba.
    const claseSeleccionada = fila.clientId === this.filaSeleccionadaClientId ? "ring-1 ring-inset ring-purple-400" : ""

    // Fase 3, Nivel A: aviso suave (nunca bloquea) cuando esta fila parece
    // repetida de otra ya cargada.
    const avisoDuplicado = esDuplicado
      ? `<span class="ml-0.5 text-amber-500 text-[10px]" title="Podría ser un duplicado de otra fila">⚠</span>`
      : ""

    const celdas = this.columns
      .map((col) => {
        const valor = fila.values[col.campo] ?? ""
        const errores = (fila.errors && fila.errors[col.campo]) || []
        const claseInput = errores.length > 0 ? "border-red-400 focus:border-red-500" : "border-gray-300 focus:border-purple-500"
        const claseTachado = fila.marcadaEliminar ? "line-through text-gray-400" : ""
        const listaId = (this.datalistIds && this.datalistIds[col.campo]) || ""

        return `<td class="px-2 py-1 align-top">
          <input type="text" class="ge-input w-full border ${claseInput} ${claseTachado} rounded text-gray-900 px-2 py-1.5 text-xs outline-none"
            value="${escaparHtml(valor)}" data-row="${i}" data-campo="${col.campo}" list="${listaId}"
            ${fila.marcadaEliminar ? "readonly" : ""}
            title="${errores.length ? escaparHtml(errores.join("; ")) : ""}" />
        </td>`
      })
      .join("")

    // Renglón NUEVO (sin persistir): "✕" lo saca directo de this.rows (ver
    // borrarFilaNueva). Renglón YA PERSISTIDO: "✕" solo TOGGLEA una marca
    // (ver toggleEliminarPersistida) — al guardar, se soft-borra directo
    // (MetadataApp.Renglones.eliminar_todos/3, sin transición: un renglón
    // no tiene estado propio, R3, así que "eliminarlo" no mueve nada del
    // encabezado). Antes acá NO había botón para filas persistidas —
    // mostrar una transición del encabezado por fila era engañoso (movía
    // el estado_id del encabezado completo, ver R3) — pero un soft-delete
    // directo no tiene ese problema, así que ahora sí se ofrece.
    const acciones = fila.marcadaEliminar
      ? `<button type="button" class="ge-quitar text-gray-500 hover:text-gray-700 text-[11px] font-semibold" data-row="${i}" title="Deshacer">↺ deshacer</button>`
      : `<button type="button" class="ge-quitar text-red-500 hover:text-red-700 font-bold" data-row="${i}" title="${fila.renglonId != null ? "Eliminar renglón" : "Quitar fila"}">✕</button>`

    // Altura fija solo mientras se virtualiza — tiene que coincidir con
    // ROW_H, si no el cálculo de los espaciadores de arriba se desalinea
    // del contenido real y el scroll salta.
    const estilo = alturaFija ? ` style="height:${ROW_H}px"` : ""

    return `<tr class="${filaClases} ${claseSeleccionada}" data-row="${i}"${estilo}>
      <td class="px-2 py-1 text-gray-400 align-top pt-2 text-[10px]">${i + 1}</td>
      <td class="px-1 py-1 align-top pt-2.5" title="${status}"><span class="inline-block w-1.5 h-1.5 rounded-full ${puntoClase}"></span>${avisoDuplicado}</td>
      ${celdas}
      <td class="px-2 py-1 text-right align-top pt-2 whitespace-nowrap">${acciones}</td>
    </tr>`
  },

  // --- Navegación ----------------------------------------------------------
  // Si la fila destino no está materializada (fuera de la ventana actual,
  // solo pasa cuando se virtualiza — Fase 2), primero hay que llevarla a la
  // ventana: mover el scroll y recalcular la ventana ANTES de buscar el
  // input en el DOM, si no `querySelector` no la va a encontrar todavía.
  enfocarCelda(row, colIdx) {
    const col = this.columns[colIdx]
    if (!col) return

    if (this.virtualizando && (row < this.ventanaInicio || row >= this.ventanaFin)) {
      this.scrollBox.scrollTop = Math.max(0, row * ROW_H - this.scrollBox.clientHeight / 2)
      this.actualizarVentana()
    }

    const el = this.tbody.querySelector(`input[data-row="${row}"][data-campo="${col.campo}"]`)
    if (el) {
      el.focus()
      el.select()
    }
  },

  reenfocar(row, campo) {
    requestAnimationFrame(() => {
      const el = this.tbody.querySelector(`input[data-row="${row}"][data-campo="${campo}"]`)
      if (!el) return
      el.focus()
      const pos = el.value.length
      el.setSelectionRange(pos, pos)
    })
  },

  moverA(row, col, wrap = false) {
    let r = row
    let c = col
    if (wrap) {
      if (c >= this.columns.length) {
        c = 0
        r += 1
      } else if (c < 0) {
        c = this.columns.length - 1
        r -= 1
      }
    }
    if (r < 0 || c < 0 || c >= this.columns.length) return
    if (r >= this.filasVisibles().length) return
    this.enfocarCelda(r, c)
  },

  // --- Estructura: insertar/duplicar/borrar filas ---------------------------
  insertarFila(idx) {
    this.rows.splice(idx, 0, filaNueva())
    this.render()
    this.enfocarCelda(idx, 0)
  },

  duplicarFila(row) {
    const fila = this.filasVisibles()[row]
    if (!fila || filaVacia(fila.values, this.columns)) return
    const copia = filaNueva()
    copia.values = {...fila.values}
    copia.dirty = new Set(Object.keys(fila.values))
    this.asegurarFila(row)
    this.rows.splice(row + 1, 0, copia)
    this.render()
    this.programarSync()
  },

  // Solo filas NUEVAS (todavía sin renglon_id) se sacan del array acá — un
  // renglón ya persistido se marca en vez de splicearse, ver
  // toggleEliminarPersistida.
  borrarFilaNueva(row) {
    const fila = this.rows[row]
    if (!fila || fila.renglonId != null) return
    this.rows.splice(row, 1)
    this.render()
    this.programarSync()
  },

  // Renglón YA PERSISTIDO: a diferencia de una fila nueva (se saca del
  // array entero), acá solo se TOGGLEA una marca — tiene que seguir
  // existiendo en this.rows para poder sincronizarse al servidor como
  // "eliminadas" (ver sincronizarAhora). El soft-delete real ocurre recién
  // al guardar (Renglones.eliminar_todos/3), nunca al tocar este botón.
  toggleEliminarPersistida(row) {
    const fila = this.rows[row]
    if (!fila || fila.renglonId == null) return
    fila.marcadaEliminar = !fila.marcadaEliminar
    this.render()
    this.programarSync()
  },

  // --- Eventos de teclado/mouse ---------------------------------------------
  alTecla(e) {
    const input = e.target.closest(".ge-input")
    if (!input) return
    const row = parseInt(input.dataset.row, 10)
    const campoIdx = this.columns.findIndex((c) => c.campo === input.dataset.campo)

    if (e.key === "Tab") {
      e.preventDefault()
      this.moverA(row, campoIdx + (e.shiftKey ? -1 : 1), true)
    } else if (e.key === "Enter") {
      e.preventDefault()
      if (e.ctrlKey) this.insertarFila(row + 1)
      else this.moverA(row + (e.shiftKey ? -1 : 1), campoIdx)
    } else if (e.key === "ArrowDown") {
      e.preventDefault()
      this.moverA(row + 1, campoIdx)
    } else if (e.key === "ArrowUp") {
      e.preventDefault()
      this.moverA(row - 1, campoIdx)
    } else if (e.key === "ArrowRight" && input.selectionStart === input.value.length) {
      e.preventDefault()
      this.moverA(row, campoIdx + 1)
    } else if (e.key === "ArrowLeft" && input.selectionStart === 0) {
      e.preventDefault()
      this.moverA(row, campoIdx - 1)
    } else if (e.key === "Escape") {
      e.preventDefault()
      const original = (this.rows[row] && this.rows[row].values[input.dataset.campo]) || ""
      input.value = original
    } else if (e.key === "Delete" && input.value === "") {
      e.preventDefault()
      this.borrarFilaNueva(row)
    } else if ((e.key === "d" || e.key === "D") && (e.ctrlKey || e.metaKey)) {
      e.preventDefault()
      this.duplicarFila(row)
    }
  },

  alEscribir(e) {
    const input = e.target.closest(".ge-input")
    if (!input) return
    const row = parseInt(input.dataset.row, 10)
    const campo = input.dataset.campo
    const eraUltimaFantasma = row === this.rows.length

    this.setCelda(row, campo, input.value)

    if (eraUltimaFantasma) {
      // La fila fantasma acaba de volverse real — hace falta una nueva
      // fantasma debajo, lo que exige un render completo (y recuperar foco).
      this.render()
      this.reenfocar(row, campo)
    } else {
      const errores = this.rows[row].errors[campo] || []
      const td = input.closest("td")
      input.classList.toggle("border-red-400", errores.length > 0)
      input.classList.toggle("border-gray-300", errores.length === 0)
      input.title = errores.join("; ")
      void td
    }

    this.programarValidacionServidor(row)
    this.programarSync()
  },

  alPegar(e) {
    const input = e.target.closest(".ge-input")
    if (!input) return
    const texto = (e.clipboardData || window.clipboardData).getData("text/plain")
    if (!texto) return
    e.preventDefault()

    const filas = parsePaste(texto)
    const rowInicio = parseInt(input.dataset.row, 10)
    const colInicio = this.columns.findIndex((c) => c.campo === input.dataset.campo)

    filas.forEach((valores, dr) => {
      const rowIdx = rowInicio + dr
      this.asegurarFila(rowIdx)
      valores.forEach((valor, dc) => {
        const col = this.columns[colInicio + dc]
        if (col) this.setCelda(rowIdx, col.campo, valor)
      })
    })

    this.render()
    this.programarSync()
  },

  alClicAccion(e) {
    const quitar = e.target.closest(".ge-quitar")
    if (quitar) {
      const row = parseInt(quitar.dataset.row, 10)
      const fila = this.rows[row]
      if (fila && fila.renglonId != null) this.toggleEliminarPersistida(row)
      else this.borrarFilaNueva(row)
      return
    }

    const accion = e.target.closest(".ge-accion")
    if (accion) {
      const row = parseInt(accion.dataset.row, 10)
      const fila = this.filasVisibles()[row]
      if (!fila || fila.renglonId == null) return
      this.pushEvent("renglon_transicion", {catalogo: this.catalogo, renglon_id: fila.renglonId, accion: accion.dataset.accion})
    }
  },

  // --- Sincronización con el servidor ---------------------------------------
  // Validación de servidor (FK, reglas del changeset): solo lo que JS no
  // puede resolver por sí solo, con debounce por fila para no mandar una
  // petición por cada tecla.
  programarValidacionServidor(row) {
    clearTimeout(this.validarTimers[row])
    this.validarTimers[row] = setTimeout(() => {
      const fila = this.rows[row]
      if (!fila) return
      this.pushEvent("grid_validar_fila", {
        catalogo: this.catalogo,
        client_id: fila.clientId,
        renglon_id: fila.renglonId,
        campos: fila.values,
      })
    }, 400)
  },

  programarSync() {
    clearTimeout(this.syncTimer)
    this.syncTimer = setTimeout(() => this.sincronizarAhora(), 500)
  },

  // Filas vacías (incluida la fantasma) nunca se mandan. "nuevas" son las
  // que todavía no tienen renglon_id; "editadas" son renglones YA
  // persistidos con al menos un campo tocado (dirty); "eliminadas" son
  // renglones YA persistidos marcados con toggleEliminarPersistida — ver
  // FichaLive.handle_event("grid_sync", ...). Una fila marcada para
  // eliminar se manda SOLO como "eliminadas" (aunque tenga campos dirty)
  // — no tiene sentido persistir ediciones de una fila que se va a borrar.
  //
  // Ojo: la vaciedad acá se mide sobre TODO fila.values, no solo
  // this.columns (columnas curadas de la grilla, ver
  // MetaSchemaContext.mostrar_en_grilla?/1) — un campo cargado SOLO desde
  // el formulario de arriba (grid_actualizar_fila) puede no estar entre
  // las columnas visibles de la grilla; si se midiera solo contra
  // this.columns, una fila con datos reales pero "vacía" a los ojos de la
  // grilla se descartaría en silencio acá.
  sincronizarAhora() {
    clearTimeout(this.syncTimer)
    const nuevas = []
    const editadas = []
    const eliminadas = []

    this.rows.forEach((fila) => {
      if (fila.renglonId != null && fila.marcadaEliminar) {
        eliminadas.push(fila.renglonId)
        return
      }
      if (!Object.values(fila.values).some((v) => !celdaVacia(v))) return
      if (fila.renglonId == null) nuevas.push(fila.values)
      else if (fila.dirty.size > 0) editadas.push({renglon_id: fila.renglonId, campos: fila.values})
    })

    this.pushEvent("grid_sync", {catalogo: this.catalogo, nuevas, editadas, eliminadas})
  },
}
