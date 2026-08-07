// FormatoNumericoField — preview de solo lectura para campos "integer"/
// "decimal" con `formato_captura` en modo "numero"/"moneda" (ver
// MetaSchemaContext.validar_formato_captura/2). El <input type="number">
// real NUNCA se reformatea en caliente (insertar comas de separador de
// miles mientras el cursor está a mitad de tipeo lo hace saltar de lugar)
// — este hook solo escribe el valor YA formateado ("$1,234.00") en el
// <span> hermano señalado por `data-preview-de`, dejando el input intacto.
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

export default {
  mounted() {
    this.preview = document.getElementById(this.el.dataset.previewDe)
    this.leerDataset()
    this.el.addEventListener("input", () => this.pintar())
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
    }
  },

  pintar() {
    if (!this.preview) return
    this.preview.textContent = formatearNumero(this.el.value, this.cfg)
  },
}
