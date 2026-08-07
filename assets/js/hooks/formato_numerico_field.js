// FormatoNumericoField — campos "integer"/"decimal" (columna numérica
// real) Y campos "string" con `formato_captura` en modo "numero"/"moneda"
// (ver MetaSchemaContext.validar_formato_captura/2). Siempre escribe el
// valor YA formateado ("$1,234.00") en el <span> hermano señalado por
// `data-preview-de`, en vivo, sin tocar el input mientras se tipea —
// insertar comas de separador de miles mientras el cursor está a mitad de
// tipeo lo hace saltar de lugar.
//
// El propio <input>, en cambio, se comporta distinto según su `type`:
//   - type="number" (columna numérica real): el navegador ya bloquea
//     letras solo, este hook no le toca el valor nunca.
//   - type="text" (columna "string" con formato número/moneda — no hay
//     protección nativa): filtra caracteres inválidos en cada tecla, y si
//     `guardar_formato` está activo, al perder foco reemplaza el valor
//     tipeado por su versión formateada — mismo interruptor que ya usa el
//     modo posicional (FormatoCapturaField) para decidir si persiste los
//     literales o no.
function formatearNumero(entrada, cfg) {
  if (entrada === "" || entrada === null || entrada === undefined) return ""

  const numero = parseFloat(entrada)
  if (Number.isNaN(numero)) return ""

  const opciones = {
    minimumFractionDigits: cfg.decimales,
    maximumFractionDigits: cfg.decimales,
    useGrouping: cfg.separadorMiles,
  }

  const textoNumero = numero.toLocaleString("es-MX", opciones)
  if (!cfg.simbolo) return textoNumero
  return cfg.simboloPosicion === "sufijo" ? `${textoNumero} ${cfg.simbolo}` : `${cfg.simbolo}${textoNumero}`
}

function filtrarNumeroTexto(entrada, permitirNegativos) {
  const negativo = permitirNegativos && entrada.trim().startsWith("-")
  let limpio = entrada.replace(/[^0-9.]/g, "")

  const puntoIdx = limpio.indexOf(".")
  if (puntoIdx !== -1) limpio = limpio.slice(0, puntoIdx + 1) + limpio.slice(puntoIdx + 1).replace(/\./g, "")

  return (negativo ? "-" : "") + limpio
}

export default {
  mounted() {
    this.preview = document.getElementById(this.el.dataset.previewDe)
    this.leerDataset()
    this.el.addEventListener("input", () => this.onInput())
    this.el.addEventListener("blur", () => this.onBlur())
    this.pintar()
  },

  updated() {
    this.leerDataset()
    this.pintar()
  },

  leerDataset() {
    this.cfg = {
      decimales: parseInt(this.el.dataset.decimales, 10) || 0,
      separadorMiles: this.el.dataset.separadorMiles === "true",
      simbolo: this.el.dataset.simbolo || "",
      simboloPosicion: this.el.dataset.simboloPosicion || "prefijo",
      permitirNegativos: this.el.dataset.permitirNegativos === "true",
      guardarFormato: this.el.dataset.guardarFormato === "true",
    }
  },

  onInput() {
    if (this.el.type === "text") {
      const filtrado = filtrarNumeroTexto(this.el.value, this.cfg.permitirNegativos)
      if (filtrado !== this.el.value) this.el.value = filtrado
    }
    this.pintar()
  },

  onBlur() {
    if (this.el.type !== "text" || !this.cfg.guardarFormato || !this.el.value) return
    const formateado = formatearNumero(this.el.value, this.cfg)
    if (formateado && formateado !== this.el.value) {
      this.el.value = formateado
      this.el.dispatchEvent(new Event("input", {bubbles: true}))
    }
  },

  pintar() {
    if (!this.preview) return
    this.preview.textContent = formatearNumero(this.el.value, this.cfg)
  },
}
