// Grid Editable Empresarial — vista de renglones de catálogos
// maestro-detalle. La tabla es de SOLO LECTURA (ver/seleccionar filas) —
// toda la edición (tipear, elegir de un desplegable) pasa por el
// formulario de arriba (FichaLive.formulario_renglon/1); acá solo se
// pinta el estado actual de this.rows y un clic en cualquier parte de una
// fila la selecciona para editarla ahí. El estado real de la tabla vive
// en this.rows (nunca en el DOM), separado de cómo se pinta (render()).
//
// El elemento raíz tiene phx-update="ignore" (ver GridEditableComponents) —
// LiveView nunca vuelve a tocar este <tbody> después del primer render, este
// hook es el único dueño de ese DOM. Actualizaciones del servidor después de
// eso (guardar, transición de un renglón, edición desde el formulario)
// llegan por push_event, nunca por un re-render de LiveView.
//
// Virtualización: con pocas filas (<= VIRTUALIZAR_DESDE) se pinta todo el
// <tbody> de una (sin altura fija, sin scroll propio). Por arriba de ese
// umbral, el contenedor `.ge-scroll` pasa a tener altura fija +
// `overflow-y: auto`, y el <tbody> solo materializa la ventana de filas
// visible (+ buffer) — el resto del alto se simula con dos filas
// espaciadoras (altura = filas fuera de la ventana × ROW_H), técnica
// estándar para virtualizar sobre un <table> real sin pelearse con
// `position: absolute` en `<tr>` (que las tablas no soportan bien).
const ROW_H = 26
const VIRTUALIZAR_DESDE = 50
const FILAS_EN_VENTANA = 15
const BUFFER_FILAS = 8

const TIPOS_NUMERICOS = ["integer", "decimal"]

function celdaVacia(valor) {
  return valor === undefined || valor === null || valor === "" || valor === "false"
}

function filaVacia(values) {
  return Object.values(values).every((v) => celdaVacia(v))
}

function escaparHtml(valor) {
  return String(valor).replace(/[&<>"']/g, (c) => ({"&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;"}[c]))
}

// Qué rango [inicio, fin) de filas materializar en el DOM dado el scroll
// actual — la única cuenta con riesgo real de bug (off-by-one, ventana
// vacía, etc.), separada de render() para poder probarla sin DOM (ver
// assets/js/hooks/__tests__/grid_editable.test.mjs). `total` ya viene
// recortado a lo que hay de verdad (this.rows.length).
export function calcularVentana(scrollTop, altoContenedor, total) {
  const inicio = Math.max(0, Math.floor(scrollTop / ROW_H) - BUFFER_FILAS)
  const fin = Math.min(total, Math.ceil((scrollTop + altoContenedor) / ROW_H) + BUFFER_FILAS)
  return {inicio, fin: Math.max(inicio, fin)}
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

// Firma de una fila para detectar posibles duplicados: valores recortados y
// en minúscula (case-insensitive) de las columnas de la tabla — barato y
// suficiente para "podría ser la misma fila dos veces", no pretende ser una
// comparación semántica.
export function firmaFila(values, columns) {
  return columns.map((c) => String(values[c.campo] ?? "").trim().toLowerCase()).join("")
}

// Índices (dentro de `filas`) que comparten firma con al menos otra fila no
// vacía. Aviso suave — nunca bloquea nada, puede haber duplicados legítimos
// (dos clientes distintos con el mismo nombre, por ejemplo).
export function detectarDuplicados(filas, columns) {
  const vistos = new Map()
  const duplicados = new Set()

  filas.forEach((fila, i) => {
    if (filaVacia(fila.values)) return
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

// Fila de resumen configurable (pie fijo, siempre al fondo de la grilla) —
// cálculo puro para poder probarlo sin DOM
// (ver assets/js/hooks/__tests__/grid_editable.test.mjs). `ventana`, si no
// es null, es {inicio, fin} (mismo shape que devuelve calcularVentana) —
// solo se usa para columnas con alcance "visibles"; sin virtualizar, todas
// las filas están "visibles" ya de por sí, así que null equivale a "todas".
// `overrides` es un mapa {campo: operacion} elegido en runtime por clic
// derecho — nunca se persiste (mismo criterio que @agregaciones del lado
// servidor, ver docs de Get View), tiene prioridad sobre la metadata.
const OPERACIONES_NUMERICAS = ["suma", "promedio", "minimo", "maximo"]
const ETIQUETAS_OPERACION = {
  suma: "Total",
  promedio: "Prom.",
  minimo: "Mín.",
  maximo: "Máx.",
  conteo: "Cant.",
  conteo_distinto: "Cant. única",
}

function valoresNoVacios(filas, campo) {
  return filas.map((f) => f.values[campo]).filter((v) => !celdaVacia(v))
}

function valoresNumericos(filas, campo) {
  return valoresNoVacios(filas, campo)
    .map((v) => Number(v))
    .filter((v) => !Number.isNaN(v))
}

function aplicarOperacionResumen(operacion, filas, campo) {
  if (operacion === "conteo") return valoresNoVacios(filas, campo).length
  if (operacion === "conteo_distinto") return new Set(valoresNoVacios(filas, campo)).size

  const valores = valoresNumericos(filas, campo)
  if (valores.length === 0) return operacion === "suma" ? 0 : null

  if (operacion === "suma") return valores.reduce((a, b) => a + b, 0)
  if (operacion === "promedio") return valores.reduce((a, b) => a + b, 0) / valores.length
  if (operacion === "minimo") return Math.min(...valores)
  if (operacion === "maximo") return Math.max(...valores)
  return null
}

function formatearResumen(valor, formato, decimales) {
  if (valor == null) return "—"
  const texto = valor.toFixed(decimales ?? 2)
  return formato === "moneda" ? `$${texto}` : texto
}

export function calcularResumen(filas, columnas, ventana, overrides = {}) {
  return columnas
    .map((col) => {
      const resumen = col.resumen
      if (!resumen) return null

      // Sin override: solo cuenta si la columna YA venía activa por
      // default (hoy, columnas numéricas — ver resumen_estandar/1 del
      // lado servidor). Con override (clic derecho), gana SIEMPRE, incluso
      // en una columna que por default no muestra nada (ej. "Recuento" en
      // una columna de texto) — si no, el clic derecho nunca podría
      // prender algo que arrancó apagado.
      const operacion = overrides[col.campo] || (resumen.activo ? resumen.operacion : "ninguno")
      if (!operacion || operacion === "ninguno") return null

      const base = resumen.alcance === "visibles" && ventana ? filas.slice(ventana.inicio, ventana.fin) : filas
      const filasCalculo = base.filter((f) => !f.marcadaEliminar && !filaVacia(f.values))

      const valor = aplicarOperacionResumen(operacion, filasCalculo, col.campo)
      const esConteo = operacion === "conteo" || operacion === "conteo_distinto"

      return {
        campo: col.campo,
        etiqueta: resumen.etiqueta || ETIQUETAS_OPERACION[operacion] || "",
        texto: esConteo ? String(valor) : formatearResumen(valor, resumen.formato, resumen.decimales),
        operacion,
        editable: resumen.editable_runtime !== false,
      }
    })
    .filter(Boolean)
}

// Validación síncrona de lo que llega del formulario (setCelda) — cubre
// requerido, tipo, y enum. Lo que esto no puede ver (existencia de FK,
// reglas del changeset) viaja al servidor por separado (ver
// programarValidacionServidor).
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

// Texto legible de una celda de solo lectura — para "referencia" resuelve
// la etiqueta ya armada por el servidor (CatalogoGenerico.opciones_referencia/1,
// mismo picker que usa el formulario) en vez del id crudo; para "boolean"
// muestra Sí/No en vez de "true"/"false".
function textoCelda(col, valor) {
  if (celdaVacia(valor)) return ""

  if (col.tipo === "referencia" && Array.isArray(col.opciones)) {
    const opcion = col.opciones.find((o) => String(o.id) === valor)
    if (opcion) return opcion.etiqueta
  }

  if (col.tipo === "boolean") return valor === "true" ? "Sí" : "No"

  return valor
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
    // Fila de resumen (ver calcularResumen) — placeholder que ya viene en
    // el HTML inicial (GridEditableComponents.grid/1, dentro del
    // <tfoot>), el hook solo le arma/actualiza el innerHTML.
    this.resumenRow = this.el.querySelector('[data-resumen-pos="abajo"]')
    // Operación elegida en runtime por clic derecho — nunca persistida,
    // se pierde si se recarga la página (mismo criterio que @agregaciones
    // de Get View).
    this.resumenOverrides = {}
    this.menuResumenEl = null
    this.el.addEventListener("contextmenu", (e) => this.alContextMenuResumen(e))
    // clientId de la fila "activa" — el formulario de
    // FichaLive.formulario_renglon/1 muestra/edita SIEMPRE esta fila (nunca
    // un modal; la tabla ya no edita nada por su cuenta). null = ninguna
    // seleccionada todavía.
    this.filaSeleccionadaClientId = null

    // Único listener de interacción: un clic en cualquier parte de una fila
    // la selecciona — la tabla es de solo lectura, no hay teclado/pegado
    // que atender acá.
    this.el.addEventListener("click", (e) => this.alClicFila(e))

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
    // que se mandan) — así guardar_edicion/1 nunca ve datos de la tabla
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

    // --- Toda la edición viaja desde el formulario de arriba ---------------

    // El formulario editó un campo de la fila seleccionada.
    this.handleEvent("grid_actualizar_fila", ({catalogo, client_id, valores}) => {
      if (catalogo !== this.catalogo) return
      const idx = this.rows.findIndex((r) => r.clientId === client_id)
      if (idx === -1) return
      Object.entries(valores).forEach(([campo, valor]) => this.setCelda(idx, campo, valor))
      this.render()
      this.programarValidacionServidor(idx)
      this.programarSync()
    })

    // "+ Nueva línea" del formulario (hoy disparado por el hook
    // RenglonForm, al confirmar con Enter o al cancelar con Esc — ya no
    // hay botón): crea una fila real en blanco y la selecciona, trayéndola
    // a la vista si está virtualizada.
    this.handleEvent("grid_nueva_fila", ({catalogo}) => {
      if (catalogo !== this.catalogo) return
      this.iniciarLineaNueva()
    })

    // Esc sobre un renglón YA PERSISTIDO (ver RenglonForm/detalle_cancelar_linea):
    // revierte values/dirty/errors a lo que había al seleccionarlo, sin
    // sacar la fila de this.rows (a diferencia de grid_quitar_fila) — así
    // grid_sync deja de mandarla como "editada" en el próximo sync.
    this.handleEvent("grid_revertir_fila", ({catalogo, renglon_id}) => {
      if (catalogo !== this.catalogo) return
      const fila = this.rows.find((f) => f.renglonId === renglon_id)
      if (!fila) return
      fila.values = {...fila.original}
      fila.dirty.clear()
      fila.errors = {}
      this.render()
      this.programarSync()
    })

    // "Eliminar línea" del formulario, para una fila TODAVÍA sin
    // renglon_id — se saca del array entero, nunca existió en la base.
    // Para un renglón YA persistido, el mismo botón manda
    // grid_marcar_eliminar en cambio (ver más abajo) — un soft-delete NO
    // es lo mismo que "nunca llegó a existir".
    this.handleEvent("grid_quitar_fila", ({catalogo, client_id}) => {
      if (catalogo !== this.catalogo) return
      const idx = this.rows.findIndex((r) => r.clientId === client_id)
      if (idx === -1 || this.rows[idx].renglonId != null) return
      this.rows.splice(idx, 1)
      if (this.filaSeleccionadaClientId === client_id) this.filaSeleccionadaClientId = null
      this.render()
      this.programarSync()
    })

    // "Eliminar línea" del formulario, para un renglón YA PERSISTIDO — a
    // diferencia de una fila nueva (se saca del array entero), acá solo
    // se TOGGLEA una marca: tiene que seguir existiendo en this.rows para
    // poder sincronizarse al servidor como "eliminadas" (ver
    // sincronizarAhora). El soft-delete real ocurre recién al guardar
    // (MetadataApp.Renglones.eliminar_todos/3), nunca al tocar este botón
    // — un renglón no tiene estado propio (R3), así que "eliminarlo" no
    // mueve nada del encabezado, a diferencia de una transición real.
    // Identificado por renglon_id (no client_id): la navegación
    // anterior/siguiente del formulario (detalle_navegar) selecciona un
    // renglón sin conocer su client_id del lado del hook.
    this.handleEvent("grid_marcar_eliminar", ({catalogo, renglon_id}) => {
      if (catalogo !== this.catalogo) return
      const fila = this.rows.find((f) => f.renglonId === renglon_id)
      if (!fila) return
      fila.marcadaEliminar = !fila.marcadaEliminar
      this.render()
      this.programarSync()
    })

    // Navegación anterior/siguiente del formulario, entre renglones YA
    // persistidos — el servidor ya resolvió cuál es y actualizó el
    // formulario con sus valores; acá solo hace falta resaltar/traer a la
    // vista esa fila.
    this.handleEvent("grid_resaltar_fila", ({catalogo, renglon_id}) => {
      if (catalogo !== this.catalogo) return
      const idx = this.rows.findIndex((f) => f.renglonId === renglon_id)
      if (idx === -1) return
      this.pararEnFila(idx)
    })

    this.render()
    // Sin botón "Agregar": la captura arranca sola, lista para tipear —
    // si nada quedó seleccionado (caso normal al entrar a la Ficha), abre
    // ya una línea nueva en blanco.
    if (this.filaSeleccionadaClientId == null) this.iniciarLineaNueva()
  },

  destroyed() {
    if (this.botonGuardar) this.botonGuardar.removeEventListener("click", this.alGuardarClick, true)
    clearTimeout(this.syncTimer)
    Object.values(this.validarTimers).forEach(clearTimeout)
    this.cerrarMenuResumen()
  },

  // Crea una fila real en blanco y la selecciona, trayéndola a la vista si
  // está virtualizada — arranque en frío (mounted, sin nada seleccionado
  // todavía) y "grid_nueva_fila" (confirmar/cancelar desde el formulario)
  // comparten exactamente este cuerpo.
  iniciarLineaNueva() {
    const idx = this.rows.length
    this.rows.push(filaNueva())
    this.render()
    this.pararEnFila(idx)
  },

  setCelda(rowIdx, campo, valor) {
    while (this.rows.length <= rowIdx) this.rows.push(filaNueva())
    const fila = this.rows[rowIdx]
    fila.values[campo] = valor
    if (fila.renglonId != null && valor !== fila.original[campo]) fila.dirty.add(campo)
    const col = this.columns.find((c) => c.campo === campo)
    fila.errors[campo] = col ? validarCelda(valor, col) : []
  },

  // --- Selección de fila (única interacción propia de la tabla) -----------
  alClicFila(e) {
    const tr = e.target.closest("tr[data-row]")
    if (!tr) return
    this.pararEnFila(parseInt(tr.dataset.row, 10))
  },

  // Si la fila no está materializada (fuera de la ventana actual, solo pasa
  // cuando se virtualiza), primero la trae a la vista.
  pararEnFila(row) {
    if (this.virtualizando && (row < this.ventanaInicio || row >= this.ventanaFin)) {
      this.scrollBox.scrollTop = Math.max(0, row * ROW_H - this.scrollBox.clientHeight / 2)
      this.actualizarVentana()
    }
    this.seleccionarFila(row)
  },

  // Le avisa al formulario de FichaLive cuál es el renglón activo, con los
  // valores que la tabla YA tiene en memoria (incluye edición del
  // formulario todavía sin sincronizar).
  seleccionarFila(rowIdx) {
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
    const filas = this.rows
    const total = filas.length
    this.virtualizando = total > VIRTUALIZAR_DESDE
    this.actualizarModoScroll()
    // Aviso suave de posibles duplicados — se recalcula en cada render, es
    // una comparación barata incluso con miles de filas.
    this.duplicados = detectarDuplicados(filas, this.columns)

    if (!this.virtualizando) {
      this.tbody.innerHTML = filas.map((fila, i) => this.filaHtml(fila, i, false, this.duplicados.has(i))).join("")
      this.renderResumen()
      return
    }

    if (this.ventanaInicio == null) {
      const inicial = calcularVentana(this.scrollBox.scrollTop, this.scrollBox.clientHeight, total)
      this.ventanaInicio = inicial.inicio
      this.ventanaFin = inicial.fin
    }

    const inicio = Math.max(0, Math.min(this.ventanaInicio, total))
    const fin = Math.max(inicio, Math.min(this.ventanaFin, total))
    const colspan = this.columns.length + 2
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
    this.renderResumen()
  },

  // Pinta las filas de resumen "arriba"/"abajo" (placeholders ya en el
  // HTML, ver GridEditableComponents.grid/1) según calcularResumen — se
  // llama al final de CADA render(), así que cubre todos los flujos que
  // mutan this.rows (setCelda, iniciar/quitar/revertir fila, marcar
  // eliminar, grid_recargar) sin duplicar lógica en cada handler, y
  // también el caso "alcance: visibles" al scrollear (actualizarVentana
  // llama a render() cuando la ventana cambió de verdad).
  renderResumen() {
    if (!this.resumenRow) return

    const ventana = this.virtualizando ? {inicio: this.ventanaInicio ?? 0, fin: this.ventanaFin ?? this.rows.length} : null
    const activos = calcularResumen(this.rows, this.columns, ventana, this.resumenOverrides)
    const porCampo = new Map(activos.map((r) => [r.campo, r]))

    this.resumenRow.style.display = activos.length > 0 ? "" : "none"
    if (activos.length === 0) {
      this.resumenRow.innerHTML = ""
      return
    }

    const celdas = this.columns
      .map((col) => {
        const r = porCampo.get(col.campo)
        if (!r) return `<td class="px-1.5 py-1" data-campo="${col.campo}"></td>`
        return `<td class="px-1.5 py-1 text-right font-semibold text-gray-700 whitespace-nowrap" data-campo="${col.campo}" data-operacion="${r.operacion}" title="${escaparHtml(r.etiqueta)}">${escaparHtml(r.texto)}</td>`
      })
      .join("")
    this.resumenRow.innerHTML = `<td class="px-1.5 py-1" colspan="2"></td>${celdas}`
  },

  // Clic derecho tipo hoja de cálculo sobre una celda de resumen —
  // reemplaza la operación configurada en la metadata, solo en memoria
  // (this.resumenOverrides), disponible en CUALQUIER columna (incluso las
  // que no suman nada por default, ver resumen_estandar/1 del lado
  // servidor) salvo que esa columna lo desactive explícitamente
  // (resumen.editable_runtime === false).
  alContextMenuResumen(e) {
    const td = e.target.closest(".ge-resumen-fila td[data-campo]")
    if (!td) return
    const col = this.columns.find((c) => c.campo === td.dataset.campo)
    if (!col || !col.resumen || col.resumen.editable_runtime === false) return

    e.preventDefault()
    this.abrirMenuResumen(e.clientX, e.clientY, col)
  },

  abrirMenuResumen(x, y, col) {
    this.cerrarMenuResumen()

    const actual = this.resumenOverrides[col.campo] || col.resumen.operacion || "ninguno"
    // Columnas no numéricas: sumar/promediar/etc no tiene sentido — solo
    // "Recuento" (cuántos renglones tienen algo cargado ahí) o nada.
    const opciones = TIPOS_NUMERICOS.includes(col.tipo)
      ? [...OPERACIONES_NUMERICAS, "conteo", "conteo_distinto", "ninguno"]
      : ["conteo", "ninguno"]

    const ul = document.createElement("ul")
    ul.className = "ge-menu-resumen"
    ul.style.cssText =
      `position:fixed;left:${x}px;top:${y}px;z-index:9999;background:#fff;border:1px solid #e5e7eb;` +
      `border-radius:6px;box-shadow:0 4px 12px rgba(0,0,0,.15);padding:4px 0;min-width:170px;` +
      `font-size:11px;font-family:inherit;list-style:none;margin:0`
    ul.innerHTML = opciones
      .map((op) => {
        const activa = op === actual
        const etiqueta = op === "ninguno" ? "Ninguno" : ETIQUETAS_OPERACION[op] || op
        return `<li data-op="${op}" style="padding:5px 12px;cursor:pointer;${activa ? "font-weight:600;color:#7c3aed" : "color:#374151"}">${activa ? "✓ " : ""}${etiqueta}</li>`
      })
      .join("")

    ul.addEventListener("mousedown", (e) => {
      const li = e.target.closest("li[data-op]")
      if (!li) return
      e.preventDefault()
      this.resumenOverrides[col.campo] = li.dataset.op
      this.cerrarMenuResumen()
      this.render()
    })

    document.body.appendChild(ul)
    this.menuResumenEl = ul

    this.alClickFueraMenuResumen = (ev) => {
      if (!ul.contains(ev.target)) this.cerrarMenuResumen()
    }
    this.alEscMenuResumen = (ev) => {
      if (ev.key === "Escape") this.cerrarMenuResumen()
    }
    // Un tick después: el mousedown que abrió el menú no debe cerrarlo de
    // una por el listener "click afuera" recién agregado.
    setTimeout(() => {
      document.addEventListener("click", this.alClickFueraMenuResumen, true)
      document.addEventListener("keydown", this.alEscMenuResumen, true)
    }, 0)
  },

  cerrarMenuResumen() {
    if (this.menuResumenEl) {
      this.menuResumenEl.remove()
      this.menuResumenEl = null
    }
    if (this.alClickFueraMenuResumen) document.removeEventListener("click", this.alClickFueraMenuResumen, true)
    if (this.alEscMenuResumen) document.removeEventListener("keydown", this.alEscMenuResumen, true)
  },

  // Fija la altura del contenedor de scroll solo cuando hay filas de sobra
  // como para justificarlo — con pocas filas la tabla se comporta como
  // cualquier tabla HTML normal, sin caja de scroll propia.
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
    const total = this.rows.length
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

    // La fila que el formulario de arriba está mostrando/editando ahora
    // mismo — un ring en vez de tocar el fondo, así convive sin pelearse
    // con los colores de status de arriba.
    const claseSeleccionada = fila.clientId === this.filaSeleccionadaClientId ? "ring-1 ring-inset ring-purple-400" : ""

    // Aviso suave (nunca bloquea) cuando esta fila parece repetida de otra
    // ya cargada.
    const avisoDuplicado = esDuplicado
      ? `<span class="ml-0.5 text-amber-500 text-[10px]" title="Podría ser un duplicado de otra fila">⚠</span>`
      : ""

    const celdas = this.columns
      .map((col) => {
        const valor = fila.values[col.campo] ?? ""
        const errores = (fila.errors && fila.errors[col.campo]) || []
        const claseTachado = fila.marcadaEliminar ? "line-through" : ""
        const claseTexto = errores.length > 0 ? "text-red-600" : fila.marcadaEliminar ? "text-gray-400" : "text-gray-700"
        const texto = escaparHtml(textoCelda(col, valor))

        return `<td class="px-1.5 py-1 align-top text-xs ${claseTexto} ${claseTachado} truncate max-w-[16rem]"
          title="${errores.length ? escaparHtml(errores.join("; ")) : ""}">${texto === "" ? "&nbsp;" : texto}</td>`
      })
      .join("")


    // Altura fija solo mientras se virtualiza — tiene que coincidir con
    // ROW_H, si no el cálculo de los espaciadores de arriba se desalinea
    // del contenido real y el scroll salta.
    const estilo = alturaFija ? ` style="height:${ROW_H}px"` : ""

    return `<tr class="cursor-pointer hover:bg-purple-50/60 ${filaClases} ${claseSeleccionada}" data-row="${i}"${estilo}>
      <td class="px-1.5 py-1 text-gray-400 align-top text-[10px]">${i + 1}</td>
      <td class="px-1 py-1 align-top" title="${status}"><span class="inline-block w-1.5 h-1.5 rounded-full ${puntoClase}"></span>${avisoDuplicado}</td>
      ${celdas}
    </tr>`
  },

  // --- Sincronización con el servidor ---------------------------------------
  // Validación de servidor (FK, reglas del changeset): solo lo que JS no
  // puede resolver por sí solo, con debounce por fila.
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

  // Filas vacías nunca se mandan. "nuevas" son las que todavía no tienen
  // renglon_id; "editadas" son renglones YA persistidos con al menos un
  // campo tocado (dirty); "eliminadas" son renglones YA persistidos
  // marcados vía grid_marcar_eliminar (botón "×" del formulario, ver
  // FichaLive.handle_event("detalle_eliminar_linea", ...)) — se mandan
  // SOLO como "eliminadas" (aunque también tengan campos dirty), no tiene
  // sentido persistir ediciones de una fila que se va a borrar.
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
      if (filaVacia(fila.values)) return
      if (fila.renglonId == null) nuevas.push(fila.values)
      else if (fila.dirty.size > 0) editadas.push({renglon_id: fila.renglonId, campos: fila.values})
    })

    this.pushEvent("grid_sync", {catalogo: this.catalogo, nuevas, editadas, eliminadas})
  },
}
