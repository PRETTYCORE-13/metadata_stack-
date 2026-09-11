# SPEC-SYS-1109202603 — BC Motor: Tab Contrato

**Documento:** Tasks · **Fase:** ✅ documentación retroactiva verificada —
no hay código para escribir ni bugs encontrados en este tab.

## Grupo A — Visibilidad y datos fuente ✅

1. [x] R1/R5 verificados: tab "api" dentro de `unless(@es_detalle?,
   ...)` (`bc_motor_live.ex:2036-2043`); documentación de un
   catálogo detalle vive en el tab Contrato de su MAESTRO
   (`renglones_detalle_doc` en `panel_api/1`).
2. [x] R13-R15 (generación de valores/orden de llaves) verificados
   contra `valor_ejemplo_campo/1` (`:1904`), `ejemplo_payload/1`
   (`:1923`), `ejemplo_registro/2` (`:1948`), `json_pretty/1` +
   `id_primero/1` (`:1963-1971`).

## Grupo B — Endpoints de lectura y renglones ✅

3. [x] R2/R3 verificados: `GET /api/:tabla` y `GET /api/:tabla/:id`
   siempre presentes; `meta_campos_detalle` solo si no está vacío
   (`agregar_si_no_vacio/3`).
4. [x] R4 verificado: una tarjeta `GET /api/:detalle?encabezado_id=:id`
   por catálogo detalle, con nota de que el filtro acepta cualquier
   campo real.

## Grupo C — Endpoints de alta ✅

5. [x] R6/R7 verificados: `payload_crear`
   (`ejemplo_payload_con_renglones/2`) vs. `payload_crear_lote`
   (ejemplo deliberadamente sin `"renglones"` por item, comentario
   explícito en el código sobre por qué).
6. [x] R8 verificado: aviso de transición de alta automática +
   ausencia intencional de un endpoint `POST /:id/transiciones/<alta>`
   (`resolver_transicion/3` nunca matchea un registro recién creado).

## Grupo D — Endpoints de transición ✅

7. [x] R9-R12 verificados contra `ejemplo_transicion/6`
   (`:3377-3417`), `separar_editables/3` (`:3424-3439`,
   separación por dueño real vía `MapSet`, no por prefijo) y
   `ejemplo_renglones/2` (`:3445-3456`, un renglón de ejemplo por
   detalle SIEMPRE).

## Grupo E — Presentación ✅

8. [x] R16/R17 verificados contra `tarjeta_endpoint/1`
   (`:3475-3501`) y el texto de "sin transiciones" al final de
   `panel_api/1`.

## Nota

Sin hallazgos reales en esta spec (a diferencia de
`SPEC-SYS-1109202602-bc-motor-tab-diagrama`, que sí encontró y
corrigió un bug de refresco) — el tab Contrato es 100% derivado en
cada render, sin estado propio que pueda desincronizarse.
