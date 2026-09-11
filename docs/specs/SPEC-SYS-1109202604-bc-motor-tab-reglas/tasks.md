# SPEC-SYS-1109202604 — BC Motor: Tab Reglas

**Documento:** Tasks · **Fase:** ✅ documentación retroactiva verificada —
no hay código para escribir ni bugs encontrados en este tab.

## Grupo A — Disponibilidad y contenido inicial ✅

1. [x] R1/R2 verificados: `compilar_disponible?/0`
   (`generar_catalogos_en_caliente`) gatea `readonly` del textarea y
   el botón Compilar, `bc_motor_live.ex:3126-3135`.
2. [x] R3 verificado: sub-tabs PRE/POST dentro de un solo `<form>`,
   `panel_reglas/1`.
3. [x] R4/R5 verificados: `MetaReglasCodigo.generar_stub/2` +
   `marcador_stub/0`, `bloque_regla/1`.

## Grupo B — Guardar/compilar ✅

4. [x] R6-R9 verificados contra `handle_event("reglas_compilar",
   ...)` + `validar_guardar_y_compilar/3`
   (`bc_motor_live.ex:1569-1603`) — sintaxis inválida no persiste
   nada; sintaxis válida siempre persiste, compilar es un paso
   aparte que puede fallar sin perder el guardado.
5. [x] R10 verificado contra `MetaReglasCodigo.sincronizado?/2`
   (código guardado vs. archivo `.ex` real en disco).

## Grupo C — Aviso de cambios sin guardar ✅

6. [x] R11/R12 verificados contra el hook `AvisoReglasSinGuardar`
   (`assets/js/app.js:779-815`) — `beforeunload` + intercepción de
   clic en fase de captura + `handleEvent("regla_guardada", ...)`
   actualizando `this.original` solo para el tipo que corresponde.

## Grupo D — Utilidad ✅

7. [x] R13 verificado: botón "Copiar" reusa el hook genérico
   `CopiarTextarea`.

## Nota

Sin hallazgos reales en esta spec — a diferencia de
`SPEC-SYS-1109202602-bc-motor-tab-diagrama`, no se encontró ningún
comportamiento roto al documentar este tab.
