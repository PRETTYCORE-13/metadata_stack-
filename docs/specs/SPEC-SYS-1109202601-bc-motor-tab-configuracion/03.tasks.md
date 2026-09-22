# SPEC-SYS-1109202601 — BC Motor: Tab Configuración

**Documento:** Tasks · **Fase:** ✅ documentación retroactiva verificada —
no hay código para escribir (spec 100% "ya construido", a pedido
explícito: "NO PROGRAMAR NADA"). Cada tarea es una verificación
punto-por-punto de `requirements.md` contra el código real citado en
`design.md`, no una tarea de implementación.

## Grupo A — Encabezado ✅

1. [x] R1/R2 verificados contra `EncabezadoBcComponents` +
   `handle_event("guardar_header", ...)` en `bc_motor_live.ex:208` —
   mismo componente que usa el asistente de alta, mismo
   `MetaSchemaContext.actualizar_header/2` de siempre.

## Grupo B — Campos ✅

2. [x] R3 (grid de campos) verificado contra `@campos =
   MetaSchemaContext.listar_detalles/1` + la tabla de
   `bc_motor_live.ex:2367-2464`, columna por columna.
3. [x] R4 (drag-and-drop) verificado: hook `ListaOrdenable`
   (`assets/js/app.js:875`, Sortable.js) → evento único `mover_a` →
   `handle_event("mover_a", ...)` (`bc_motor_live.ex:851`) →
   `MetaSchemaContext.reordenar_campos/2` (solo metadata, sin ALTER).
4. [x] R5/R6 (Formato captura/fecha) verificados contra los botones
   condicionados por tipo, `bc_motor_live.ex:2430-2440`.
5. [x] R7 (Configurar + Cascada para referencia) verificado — dos
   botones independientes, `bc_motor_live.ex:2441-2453`, y su
   contraparte en el tab Relaciones (`panel_relaciones/1`, mismos
   `handle_event`).
6. [x] R8 (Eliminar campo) verificado contra
   `CatalogoGenerador.eliminar_campo/4` — confirmación tipeada
   (`validar_confirmacion/2`), `DROP COLUMN` real
   (`quitar_columna/2`), auditoría (`MetaAuditoriaDefinicion.registrar/4`).
   **Corrección real durante la verificación**: el primer borrador de
   `requirements.md` decía "pide confirmación" en genérico — el
   mecanismo real exige tipear el nombre del campo, más fuerte que un
   diálogo sí/no. Corregido en `requirements.md` antes de seguir.
7. [x] R9 (Agregar campo) verificado contra
   `handle_event("guardar_campo_asistente", ...)` →
   `FieldDesignerComponents.construir_propiedades/3` →
   `guardar_campo_y_generar/4` → `CatalogoGenerador.generar/1`
   (rama retrofit, reusa el generador de catálogo nuevo) — "Valor por
   default" ya documentado en `catalogo-maestro-detalle-requerimientos.md` R13.
   **Corrección real durante la verificación**: `design.md` primero
   afirmó una función `CatalogoGenerador.agregar_campo/2` que no
   existe — corregido con el nombre real (`generar/1`) tras grep
   directo.

## Grupo C — Estados ✅

8. [x] R10 (gate por campos) verificado: `@puede_agregar` de
   `tabla_estados/1` = `@campos != []`.
9. [x] R11/R12 (estado inicial forzado) verificado contra
   `MetaEstadosAdmin.crear_estado/1` →
   `forzar_inicial_si_es_el_primero/1` (`meta_estados_admin.ex:58`) +
   `modal_estado/1` (`bc_motor_live.ex:4302`).
10. [x] R13 (eliminar estado) verificado: botón condicionado a
    `not MapSet.member?(@referenciados, estado.id)` en
    `tabla_estados/1`.

## Grupo D — Transiciones ✅

11. [x] R14 (gate por estado inicial) verificado: `@puede_agregar` de
    `tabla_transiciones/1` = existe algún `es_inicial: true`.
12. [x] R15/R16 (tabla + aviso self-loop) verificado contra
    `tabla_transiciones/1`, `bc_motor_live.ex:2935-3007`.
13. [x] R17 (self-loop `"guardar"` como convención de PATCH)
    verificado contra `MetaStateEngine.transicion_guardar/2`
    (`meta_state_engine.ex:178-190`) — búsqueda exacta por
    `accion == "guardar"` + mismo origen/destino.
    **Corrección real durante la verificación**: `design.md` primero
    atribuyó esto a `MetaTransicionController`/`CatalogoGenerico.actualizar/2`
    sin haberlo verificado — corregido con la función real tras grep.
14. [x] R18 (form Origen/Destino) verificado contra `modal_transicion/1`.
15. [x] R19 (tabs de campos editables por catálogo detalle) verificado
    contra `modal_transicion/1` + `.grupo_campos_editables/1`,
    `@catalogos_detalle` desde `MetaSchemaContext.listar_catalogos_detalle/1`.
16. [x] R20/R21 (permisos por transición) verificado contra
    `permisos_transicion/3` (`bc_motor_live.ex:180-186`) +
    `handle_event("registrar_permiso_transicion", ...)`
    (`bc_motor_live.ex:1389-1401`).

## Grupo E — Stepper de completitud ✅

17. [x] R22/R23 verificados contra `pasos_motor/5`
    (`bc_motor_live.ex:2225-2277`) y
    `MetaEstadosAdmin.completitud/1` (`meta_estados_admin.ex:479`).

## Nota — hallazgos reales registrados en `design.md` §7

No son tareas de esta spec (son comportamiento de `CatalogoGenerico`/
`MetaStateEngine`, fuera del tab Configuración en sí), pero se
originaron revisando este tab en la misma sesión, así que quedan
enlazados acá para no perder el rastro:

- Índice único de estado inicial sin filtrar `delete_guid` (corregido,
  migración `20260910193000_filtrar_borrados_en_indice_estado_inicial.exs`).
- `CatalogoGenerico.crear/2` ahora exige al menos un estado
  (`MetaStateEngine.estado_inicial/1`) para cualquier catálogo BC de
  negocio, no solo transición "alta" formal.
