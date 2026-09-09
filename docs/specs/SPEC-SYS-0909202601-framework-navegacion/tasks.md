# SPEC-SYS-0909202601 — Framework de Navegación

**Documento:** Tasks (incremento 2026-09-09: menú administrativo
reorganizado + acceso desde el sidebar) · **Fase:** ✅ implementado y
compilando; verificación de código completa, **falta confirmación
visual en navegador** (sin herramienta de navegador en esta sesión).
Ver `requirements.md` §3 (R13/R13a/R13b/R13c/R22) y `design.md` §7.

## Grupo A — Backend: separar los dos grupos de opciones ✅

1. [x] `opciones_administrativas_visibles/1` en `MenuLayout` (privada,
   mismo patrón que la función que reemplaza) — filtra las 5
   capacidades administrativas contra `can?/3`, sin gate extra.
2. [x] `opciones_plataforma_visibles/2` — `[]` inmediato si
   `usuario.super_admin != true` (pattern match, sin ni siquiera
   consultar `can?/3`); si es `true`, filtra las 4 de plataforma +
   BPB/Tepache solo si `bpb_habilitado`.
3. [x] Verificado con script real: el usuario sysadmin local
   (`super_admin: true`, además "administrador" de sistema) resuelve
   `can?/3 == true` en las 9 capacidades; con `super_admin` forzado a
   `false` (razonamiento sobre el pattern match, no hace falta
   ejecutarlo — es una igualdad incondicional, no puede comportarse
   distinto) el grupo plataforma cae siempre a `[]`.

## Grupo B — Componente de dropdown compartido ✅

4. [x] Contenido extraído a `menu_administrativo/1` (function
   component nuevo), recibe `id`, `opciones_administrativas`,
   `opciones_plataforma`, `current_scope` — misma estructura HEEx de
   antes (submenu "Deploy" anidado, etc.), ahora también recibe qué
   `id` de dropdown target-ea el `JS.hide`/`JS.push` (antes hardcoded a
   `#user-menu-dropdown`).
5. [x] El dropdown de la topbar ahora renderiza
   `<.menu_administrativo id="user-menu-dropdown" .../>`.
6. [ ] **Pendiente — confirmación visual**: que el dropdown de la
   topbar se siga viendo/comportando igual que antes del refactor.

## Grupo C — Ícono de engrane en el sidebar ✅ (código) / ⏳ (visual)

7. [x] Botón de engrane agregado como hermano de `.pc-sidebar-body`
   dentro de `<aside>` — al tener `.pc-sidebar-body` `flex:1`, este
   nuevo bloque queda pegado al fondo del riel sin CSS adicional de
   posicionamiento vertical.
8. [x] Segunda instancia de `<.menu_administrativo id="sidebar-config-dropdown" .../>`,
   con override de posición por id (`#sidebar-config-dropdown`: abre
   hacia arriba y a la derecha del riel, mismo lado que el flyout de
   carpetas).
9. [x] `:if={@opciones_administrativas_visibles != [] or
   @opciones_plataforma_visibles != []}` en el `<div class="pc-sidebar-config">`
   completo — sin nada que mostrar, ni el botón se renderiza.
10. [ ] **Pendiente — confirmación visual**: que el ícono aparezca, abra
    el mismo contenido que el avatar, cierre al click afuera, y no
    rompa el resize/collapse del sidebar. **Esto necesita que lo
    confirmes vos en `http://127.0.0.1:4000`** — no tengo forma de
    operar el navegador en esta sesión.

## Grupo D — Verificación end-to-end real

11. [x] Usuario sysadmin real de developer local: confirmado por script
    que ve ambos grupos completos (incluye BPB/Tepache, `bpb_habilitado`
    true en dev).
12. [x] Gate de `super_admin` confirmado como incondicional (ver tarea
    3) — un usuario sin ese flag NUNCA ve el grupo plataforma, sin
    importar sus permisos RBAC.
13. [x] `mix test`: 507 tests, 0 failures (la corrida con 1 falla fue un
    flake de un test property-based/`StreamData` sobre TRN, no
    relacionado a este cambio — confirmado limpio en la corrida
    siguiente).
