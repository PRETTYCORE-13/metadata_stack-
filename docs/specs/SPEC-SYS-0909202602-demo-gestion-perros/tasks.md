# SPEC-SYS-0909202602 — Demo: Gestión de Perros

**Documento:** Tasks · **Fase:** ✅ aprobada (2026-09-09) — **ejecutada y
verificada el mismo día**. Hecho por Claude vía las mismas funciones que
usa la UI del Motor BC (`MetaEstadosAdmin.crear_proceso_completo/1`,
`CatalogoGenerador.generar/1`, `Permissions.conceder_permisos_catalogo/2`,
`CatalogoGenerico.crear/4`, `MetaStateEngine.ejecutar_transicion/3`) —
sin editar ningún schema/migración a mano, el único código nuevo en
disco es el que `CatalogoGenerador` escribió solo
(`lib/metadata_app/meta_business_process/catalogos/pty_perros.ex`). Las
tareas 8/12 (visibilidad en el menú) se confirmaron contra la misma
lógica de permisos que usa la UI (`Permissions.permisos_de_usuario/2`,
`administrador?/2`), no con una captura de navegador — no hay
herramienta de navegador disponible en esta sesión.

## Grupo A — El catálogo (Header + campos) ✅

1. [x] Header `pty_perros` creado (id 48) con las propiedades de
   `design.md` §1.
2. [x] Los 5 campos de `design.md` §2 creados con tipo/obligatoriedad
   correctos (confirmado columna por columna contra
   `information_schema.columns`).
3. [x] Tabla física `pty_perros` existe en Postgres (11 columnas: 5 de
   negocio + `estado_id`/`fecha_registro`/guids de sistema) y
   `pty_perros.ex` quedó generado con los 5 campos y sus tipos/límites
   exactos (`longitud: 200` en `nombre_dueno` incluido).

## Grupo B — Estados y transiciones ✅

4. [x] Estados **Activo** (inicial, orden 1) y **Baja** (orden 2)
   creados.
5. [x] Transiciones `alta` (→Activo), `dar_de_baja` (Activo→Baja),
   `reactivar` (Baja→Activo) creadas.
6. [x] Autómata correcto — confirmado por consulta directa a
   `meta_schema_estados`/`meta_schema_transiciones` (2 estados, 3
   transiciones, sin errores del `Ecto.Multi` de
   `crear_proceso_completo/1`).

## Grupo C — RBAC ✅

7. [x] Los 4 permisos (`leer`, `alta`, `dar_de_baja`, `reactivar` sobre
   `pty_perros`) concedidos al rol `pty-dsd-admin` (id 14).
8. [x] Visibilidad en menú confirmada por lógica de permisos: el
   usuario de prueba (`sysadmin@metadata.local`) es `administrador`
   (bypass total, `Permissions.administrador?/2` → `true`), mismo
   mecanismo que decide qué se muestra en `podar_menu_por_permisos/1`
   — "Perros" le aparece sin depender siquiera del grant del paso 7.

## Grupo D — Verificación end-to-end real (developer local) ✅

9. [x] Alta real: perro "Firulais" (Labrador, 3 años, con observaciones
   y dueño) creado vía `CatalogoGenerico.crear/4` — quedó en estado
   **Activo**, `delete_guid: nil`.
10. [x] "Dar de baja" ejecutada vía `MetaStateEngine.ejecutar_transicion/3`
    — pasó a **Baja**, `delete_guid` siguió `nil` (nunca se borró la
    fila), evento quedó registrado en `meta_schema_transicion_eventos`.
11. [x] "Reactivar" ejecutada — volvió a **Activo**. `Repo.aggregate(count)`
    confirma: sigue existiendo 1 sola fila en todo momento (nunca hubo
    un segundo insert ni un delete).
12. [x] El catálogo se resuelve con la misma lógica RBAC que cualquier
    otro (ver tarea 8) — el permiso `"leer"` es lo único que decide
    visibilidad, sin caso especial para `pty_perros`.

Sin Grupo E de publicación — `requirements.md` §5 lo deja
explícitamente fuera de alcance; queda en developer.
