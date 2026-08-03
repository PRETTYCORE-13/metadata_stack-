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
import {computeStatus, calcularVentana, firmaFila, detectarDuplicados} from "../grid_editable.js"

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
