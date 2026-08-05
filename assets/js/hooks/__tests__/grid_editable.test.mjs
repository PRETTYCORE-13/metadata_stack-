// Tests de las únicas funciones puras (sin DOM) del hook GridEditable —
// las de mayor riesgo de bug silencioso (ventana de virtualización, estado
// visual de una fila, detección de duplicados). Todo lo que depende del DOM
// (clic, foco) no se puede probar acá sin navegador headless (no disponible
// en este entorno, ver docs/catalogo-maestro-detalle-requerimientos.md
// Fase 7) — se verifica manualmente en un navegador real.
//
// Corre con el test runner nativo de Node (>= 18), sin dependencias
// nuevas: `node --test assets/js/hooks/__tests__/grid_editable.test.mjs`

import {test} from "node:test"
import assert from "node:assert/strict"
import {computeStatus, calcularVentana, firmaFila, detectarDuplicados, calcularResumen} from "../grid_editable.js"

// ROW_H=26, BUFFER_FILAS=8 (constantes internas de grid_editable.js) —
// hardcodeados acá a propósito: si alguien los cambia sin darse cuenta de
// que afectan la ventana visible, estos tests tienen que fallar.
test("calcularVentana: arranque en el tope, con buffer hacia abajo", () => {
  assert.deepEqual(calcularVentana(0, 495, 1000), {inicio: 0, fin: 28})
})

test("calcularVentana: scrolleado a la mitad, buffer para ambos lados", () => {
  assert.deepEqual(calcularVentana(3300, 495, 1000), {inicio: 118, fin: 154})
})

test("calcularVentana: cerca del final, el fin nunca pasa del total", () => {
  assert.deepEqual(calcularVentana(25500, 495, 1000), {inicio: 972, fin: 1000})
})

test("calcularVentana: menos filas que el buffer, la ventana cubre todo sin pasarse", () => {
  assert.deepEqual(calcularVentana(0, 495, 5), {inicio: 0, fin: 5})
})

test("calcularVentana: sin filas, ventana vacía sin romper (fin nunca queda antes que inicio)", () => {
  assert.deepEqual(calcularVentana(0, 495, 0), {inicio: 0, fin: 0})
})

test("computeStatus: fila sin renglon_id es 'nueva'", () => {
  const fila = {renglonId: null, dirty: new Set(), errors: {}}
  assert.equal(computeStatus(fila), "nueva")
})

test("computeStatus: fila persistida sin cambios es 'sin_cambios'", () => {
  const fila = {renglonId: 3, dirty: new Set(), errors: {}}
  assert.equal(computeStatus(fila), "sin_cambios")
})

test("computeStatus: fila persistida con algún campo tocado es 'modificada'", () => {
  const fila = {renglonId: 3, dirty: new Set(["contacto"]), errors: {}}
  assert.equal(computeStatus(fila), "modificada")
})

test("computeStatus: cualquier error gana, incluso sobre una fila nueva", () => {
  const fila = {renglonId: null, dirty: new Set(), errors: {contacto: ["obligatorio"]}}
  assert.equal(computeStatus(fila), "error")
})

test("computeStatus: un campo con lista de errores vacía no cuenta como error", () => {
  const fila = {renglonId: 3, dirty: new Set(), errors: {contacto: []}}
  assert.equal(computeStatus(fila), "sin_cambios")
})

test("computeStatus: fila marcada para eliminar es 'eliminar'", () => {
  const fila = {renglonId: 3, dirty: new Set(), errors: {}, marcadaEliminar: true}
  assert.equal(computeStatus(fila), "eliminar")
})

test("computeStatus: marcada para eliminar gana incluso sobre un error", () => {
  const fila = {renglonId: 3, dirty: new Set(), errors: {contacto: ["obligatorio"]}, marcadaEliminar: true}
  assert.equal(computeStatus(fila), "eliminar")
})

test("firmaFila: mismos valores en distinto caso/espacios dan la misma firma", () => {
  const columnas = [{campo: "nombre"}, {campo: "tel"}]
  assert.equal(firmaFila({nombre: "Juan", tel: "555"}, columnas), firmaFila({nombre: " juan ", tel: "555"}, columnas))
})

test("firmaFila: un valor distinto cambia la firma", () => {
  const columnas = [{campo: "nombre"}]
  assert.notEqual(firmaFila({nombre: "Juan"}, columnas), firmaFila({nombre: "Pedro"}, columnas))
})

test("detectarDuplicados: dos filas iguales quedan las dos marcadas", () => {
  const columnas = [{campo: "nombre"}]
  const filas = [{values: {nombre: "Juan"}}, {values: {nombre: "Pedro"}}, {values: {nombre: "Juan"}}]
  assert.deepEqual(detectarDuplicados(filas, columnas), new Set([0, 2]))
})

test("detectarDuplicados: filas vacías nunca cuentan como duplicadas entre sí", () => {
  const columnas = [{campo: "nombre"}]
  const filas = [{values: {nombre: ""}}, {values: {nombre: ""}}]
  assert.deepEqual(detectarDuplicados(filas, columnas), new Set())
})

test("detectarDuplicados: sin repetidos, ninguna fila se marca", () => {
  const columnas = [{campo: "nombre"}]
  const filas = [{values: {nombre: "Juan"}}, {values: {nombre: "Pedro"}}]
  assert.deepEqual(detectarDuplicados(filas, columnas), new Set())
})

// --- calcularResumen ------------------------------------------------------

function filaCon(cantidad, extra = {}) {
  return {values: {cantidad: cantidad ?? ""}, marcadaEliminar: false, ...extra}
}

const colCantidadSuma = {campo: "cantidad", tipo: "decimal", resumen: {activo: true, operacion: "suma"}}

test("calcularResumen: suma de una columna numérica", () => {
  const filas = [filaCon("10"), filaCon("5.5"), filaCon("4.5")]
  const resultado = calcularResumen(filas, [colCantidadSuma], null)
  assert.deepEqual(resultado, [{campo: "cantidad", etiqueta: "Total", texto: "20.00", operacion: "suma", editable: true}])
})

test("calcularResumen: promedio, mínimo y máximo", () => {
  const filas = [filaCon("10"), filaCon("20"), filaCon("30")]
  const promedio = calcularResumen(filas, [{...colCantidadSuma, resumen: {activo: true, operacion: "promedio"}}], null)
  const minimo = calcularResumen(filas, [{...colCantidadSuma, resumen: {activo: true, operacion: "minimo"}}], null)
  const maximo = calcularResumen(filas, [{...colCantidadSuma, resumen: {activo: true, operacion: "maximo"}}], null)
  assert.equal(promedio[0].texto, "20.00")
  assert.equal(minimo[0].texto, "10.00")
  assert.equal(maximo[0].texto, "30.00")
})

test("calcularResumen: recuento y recuento distinto cuentan valores no vacíos", () => {
  const columnas = [{campo: "categoria", tipo: "string", resumen: {activo: true, operacion: "conteo"}}]
  const filas = [{values: {categoria: "A"}}, {values: {categoria: "A"}}, {values: {categoria: ""}}]
  assert.equal(calcularResumen(filas, columnas, null)[0].texto, "2")

  const columnasDistinto = [{campo: "categoria", tipo: "string", resumen: {activo: true, operacion: "conteo_distinto"}}]
  assert.equal(calcularResumen(filas, columnasDistinto, null)[0].texto, "1")
})

test("calcularResumen: formato moneda y decimales configurables", () => {
  const columnas = [{campo: "cantidad", tipo: "decimal", resumen: {activo: true, operacion: "suma", formato: "moneda", decimales: 0}}]
  const filas = [filaCon("10.4"), filaCon("5.4")]
  assert.equal(calcularResumen(filas, columnas, null)[0].texto, "$16")
})

test("calcularResumen: filas vacías y marcadas para eliminar se excluyen del cálculo", () => {
  const filas = [filaCon("10"), filaCon(""), filaCon("5", {marcadaEliminar: true})]
  assert.equal(calcularResumen(filas, [colCantidadSuma], null)[0].texto, "10.00")
})

test("calcularResumen: columna sin resumen activo no aparece en el resultado", () => {
  const columnas = [{campo: "cantidad", tipo: "decimal", resumen: {activo: false, operacion: "suma"}}, {campo: "otra", tipo: "string"}]
  const filas = [filaCon("10")]
  assert.deepEqual(calcularResumen(filas, columnas, null), [])
})

test("calcularResumen: operación 'ninguno' (por override o metadata) desactiva la columna", () => {
  const filas = [filaCon("10")]
  assert.deepEqual(calcularResumen(filas, [colCantidadSuma], null, {cantidad: "ninguno"}), [])
})

test("calcularResumen: override en runtime tiene prioridad sobre la operación de la metadata", () => {
  const filas = [filaCon("10"), filaCon("20")]
  const resultado = calcularResumen(filas, [colCantidadSuma], null, {cantidad: "maximo"})
  assert.equal(resultado[0].operacion, "maximo")
  assert.equal(resultado[0].texto, "20.00")
})

test("calcularResumen: etiqueta custom de la metadata gana sobre la derivada de la operación", () => {
  const columnas = [{...colCantidadSuma, resumen: {...colCantidadSuma.resumen, etiqueta: "Suma total"}}]
  const filas = [filaCon("10")]
  assert.equal(calcularResumen(filas, columnas, null)[0].etiqueta, "Suma total")
})

test("calcularResumen: alcance 'visibles' solo calcula sobre la ventana virtualizada", () => {
  const columnas = [{...colCantidadSuma, resumen: {...colCantidadSuma.resumen, alcance: "visibles"}}]
  const filas = [filaCon("10"), filaCon("20"), filaCon("30"), filaCon("40")]
  const resultado = calcularResumen(filas, columnas, {inicio: 1, fin: 3})
  assert.equal(resultado[0].texto, "50.00")
})

test("calcularResumen: override activa una columna que por default no muestra nada (ej. 'Recuento' en una columna de texto)", () => {
  const columnas = [{campo: "producto", tipo: "string", resumen: {activo: false, operacion: "ninguno", editable_runtime: true}}]
  const filas = [{values: {producto: "100"}}, {values: {producto: "200"}}, {values: {producto: ""}}]
  const resultado = calcularResumen(filas, columnas, null, {producto: "conteo"})
  assert.deepEqual(resultado, [{campo: "producto", etiqueta: "Cant.", texto: "2", operacion: "conteo", editable: true}])
})

test("calcularResumen: alcance 'visibles' sin virtualizar (ventana null) calcula sobre todas las filas", () => {
  const columnas = [{...colCantidadSuma, resumen: {...colCantidadSuma.resumen, alcance: "visibles"}}]
  const filas = [filaCon("10"), filaCon("20")]
  assert.equal(calcularResumen(filas, columnas, null)[0].texto, "30.00")
})
