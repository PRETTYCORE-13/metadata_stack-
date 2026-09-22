# SPEC-SYS-1109202605 — BC Motor: Tab Permisos y Alcance de Datos

**Documento:** Tasks · **Fase:** ✅ documentación retroactiva verificada —
no hay código para escribir ni bugs encontrados en este tab.

## Grupo A — Montaje embebido y matriz de permisos ✅

1. [x] R1 verificado: "permisos" dentro de `unless(@es_detalle?,
   ...)`, `bc_motor_live.ex:2039-2041` + `live_render/3` con
   `session: %{"recurso" => ...}`.
2. [x] R2/R2a verificados contra `cargar_matriz/1`
   (`catalogo_permisos_live.ex:325-388`) — `acciones_crud` distinto
   por tipo de catálogo (Consulta / detalle / normal).
3. [x] R3-R5 verificados contra `toggle_permiso`/`conceder_todos`/
   `revocar_todos` (`:217-263`) y la fila fija de "administrador" en
   el render.

## Grupo B — Filtro y Alcance de Datos ✅

4. [x] R6/R7 verificados: `@modo`, `Permissions.listar_roles/2` vs.
   `roles_de_usuario/2`, guardia doble de `mostrar_sysadmin?`.
5. [x] R8-R10 verificados contra `catalogo_base_de_consulta/1` y
   `toggle_alcance_habilitado` (`:294-321`) —
   `provisionar_alcance/1` vs. `actualizar_header(%{"alcance_habilitado" => false})`.
6. [x] R11-R14 verificados contra `panel_alcance_de_rol/1` y
   `cambiar_alcance_tipo` (`:265-283`) — `@roles_con_permiso`,
   `@tipos_alcance` ordenado, default `:propio`.

## Grupo C — Permisos de detalle por estado ✅

7. [x] R15-R17 verificados contra `tabla_permisos_detalle/1` +
   `toggle_permiso_detalle/1` (`bc_motor_live.ex:3022-3082`) y
   `MetaEstadosAdmin.permiso_detalle/2` (`meta_estados_admin.ex:239-`).

## Nota

Sin hallazgos reales (bugs) en esta spec. Sí se documentó una
distinción real no obvia a simple vista: tres mecanismos de permisos
completamente independientes conviven en el mismo tab visual (RBAC
por rol, Alcance de Datos por rol, Permisos de detalle por estado del
maestro) — ninguno de los tres consulta al otro.
