# SPEC-SYS-0909202601 — Framework de Navegación

**Documento:** Tasks (incremento 2026-09-09: menú administrativo
reorganizado + acceso desde el sidebar) · **Fase:** ✅ implementado y
confirmado visualmente por el usuario en developer local. Ver
`requirements.md` §3 (R12/R13/R13a/R13b/R13c/R22) y `design.md` §7.

> **Reconciliado 2026-09-09** — este documento se había quedado
> desactualizado: describía la PRIMERA versión (dropdown compacto, dos
> accesos: avatar + engrane) y nunca se volvió a tocar después de dos
> correcciones reales pedidas el mismo día (sacar el acceso del avatar,
> rediseñar el panel al estilo flyout). Grupo E y F de abajo son esas
> dos correcciones — antes solo vivían en `requirements.md`/`design.md`,
> nunca en `tasks.md`. Grupo B, tareas 4-6, quedan marcadas
> explícitamente como SUPERADAS por Grupo E, no borradas — el historial
> de qué se intentó primero importa tanto como el estado final.

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
   distinto) el grupo plataforma cae siempre a `[]`. Sigue vigente sin
   cambios pese a Grupo E/F — el backend nunca se tocó de nuevo.

## Grupo B — Componente de dropdown compartido (versión 1, SUPERADA por Grupo E) ⚠️

4. [x] Contenido extraído a `menu_administrativo/1` (function
   component nuevo) — versión inicial, visual de dropdown compacto
   (`.pc-user-menu-dropdown`, sin íconos).
5. [x] ~~El dropdown de la topbar ahora renderiza
   `<.menu_administrativo id="user-menu-dropdown" .../>`~~ — **YA NO
   ES CIERTO, ver Grupo E tarea 15**: el avatar de la topbar dejó de
   tener dropdown asociado, a pedido explícito del mismo día.
6. [x] Confirmación visual del dropdown de la topbar (versión 1) — el
   usuario reportó "no abre el menú" (bug real, no un check pendiente
   sin resolver): `.pc-platform-sidebar` tiene `overflow: hidden`
   (necesario para la animación de expandir/colapsar) y recortaba el
   `position: absolute` del panel del engrane. Corregido con
   `position: fixed` + coordenadas fijas según el riel esté colapsado o
   expandido.

## Grupo C — Ícono de engrane en el sidebar ✅

7. [x] Botón de engrane agregado como hermano de `.pc-sidebar-body`
   dentro de `<aside>` — al tener `.pc-sidebar-body` `flex:1`, este
   bloque queda pegado al fondo del riel sin CSS adicional de
   posicionamiento vertical.
8. [x] Segunda instancia de `<.menu_administrativo .../>` con `id`
   propio (`#sidebar-config-dropdown`), posición corregida en la tarea
   6 de arriba.
9. [x] `:if={@opciones_administrativas_visibles != [] or
   @opciones_plataforma_visibles != []}` en el `<div class="pc-sidebar-config">`
   completo — sin nada que mostrar, ni el botón se renderiza.
10. [x] Confirmación visual real del usuario ("el menu ya esta bien")
    — llegó DESPUÉS de Grupo F (rediseño estilo flyout), confirma esa
    versión final, no la del dropdown compacto original.

## Grupo D — Verificación end-to-end real (backend) ✅

11. [x] Usuario sysadmin real de developer local: confirmado por script
    que ve ambos grupos completos (incluye BPB/Tepache, `bpb_habilitado`
    true en dev).
12. [x] Gate de `super_admin` confirmado como incondicional — un
    usuario sin ese flag NUNCA ve el grupo plataforma, sin importar sus
    permisos RBAC.
13. [x] `mix test`: 507 tests, 0 failures (la corrida con 1 falla fue un
    flake de un test property-based/`StreamData` sobre TRN, no
    relacionado a este cambio — confirmado limpio en la corrida
    siguiente).

## Grupo E — Corrección: único acceso desde el engrane (mismo día, a pedido explícito) ✅

> Motivo: "el menu ya esta bien, quitalo del la imagen del usuario,
> solo se puede acceder al menu desde el engrane" — ver
> `requirements.md` R12/R22 actualizados.

14. [x] `requirements.md`/`design.md` actualizados PRIMERO (R12
    corregido, nota de corrección en R22 y en §7) — recién después se
    tocó código, mismo orden que toda esta spec.
15. [x] Botón de usuario de la topbar (`pc-user-menu-btn`) pasa de
    `<button phx-click={JS.toggle...}>` a `<div>` puramente informativo
    — sin `cursor:pointer` ni `:hover` en el CSS, ya no dispara nada.
16. [x] Instancia `<.menu_administrativo id="user-menu-dropdown" .../>`
    eliminada de la topbar por completo — único acceso real: el engrane
    del sidebar (`#sidebar-config-dropdown`).
17. [x] `mix compile` limpio + servidor reiniciado + verificado que
    sigue respondiendo (`HTTP 302`).

## Grupo F — Corrección: panel estilo flyout de catálogos (mismo día, a pedido explícito) ✅

> Motivo: "usa el mismo menu como se muestran los bd de negocio, no
> tiene caso generar un UI diferente, se ve mal" + "No poner etiqueta
> de configuración" + "en lugar de DSD dirá Configuración en menu".

18. [x] `menu_administrativo/1` reescrito: header con título
    "Configuración" + botón X (reusa `.pc-flyout-header`/
    `.pc-flyout-cerrar`/`.pc-flyout-nav`, las mismas clases del flyout
    de catálogos de negocio) en vez del dropdown compacto sin íconos de
    Grupo B.
19. [x] Cada opción con ícono Material Symbols + etiqueta (`.pc-admin-menu-item`/
    `.pc-admin-menu-icon`/`.pc-admin-menu-label`, clases nuevas — NO
    reusan `.pc-nav-item`/`.pc-nav-icon` del árbol real porque esas
    dependen de `.pc-platform-sidebar-open`/`.pc-sidebar-flyout` como
    ancestro para decidir tamaño/opacidad, y este panel no vive ahí).
20. [x] Etiqueta "Configuración" sacada del botón del engrane (queda
    solo el ícono, siempre centrado) — vive en el header del panel en
    su lugar, no se perdió, se movió.
21. [x] Bug encontrado y corregido el mismo día: en tema claro el
    engrane era invisible (`color: rgba(255,255,255,0.85)` sobre fondo
    de sidebar blanco) — agregado el mismo override de color que ya
    usan `.pc-sidebar-toggle`/`.pc-theme-btn` en `:root[data-theme="light"]`.
22. [x] Confirmación visual real del usuario sobre esta versión final
    (ver Grupo C tarea 10).

## Nota — fix relacionado, fuera del alcance de este incremento

Durante Grupo F se encontró (no se pidió, apareció al revisar el
mismo flyout de catálogos por el punto de comparación) que
`.pc-nav-label` dentro de `.pc-sidebar-flyout` partía nombres largos en
2 líneas truncadas ("Patrón de Frecuencias" → "Patr"/"Frec"). Se
corrigió a una sola línea con ellipsis — esto es un fix sobre R5
(flyout de carpetas, documentado desde la fase retroactiva), no sobre
el menú administrativo de este incremento, pero vive en el mismo
`menu.css` así que se registra acá para que no quede sin rastro en
ningún lado.

**Segundo fix relacionado, mismo día (2026-09-10)** — también sobre R5,
también fuera del alcance de este incremento: los íconos de página
dentro del flyout (`.pc-sidebar-flyout .pc-nav-icon`) se veían
desproporcionados. Encontrado en vivo con DevTools + varias vueltas de
ajuste junto al usuario:
1. 15px se veía "grande y raro" al lado de la etiqueta de 10px —
   confirmado con el panel Computed que el tamaño SÍ se aplicaba
   correcto (no era un problema de cascade/especificidad).
2. Al bajar a 12px×12px exacto (contenedor = glyph), el ícono empezó a
   verse CORTADO — el glyph de Material Symbols no entra completo en
   su propio `font-size` nominal, y `overflow: hidden` del contenedor
   se lo recortaba.
3. Fix final: contenedor MÁS GRANDE que el glyph (aire de sobra para
   no recortar), tamaño percibido controlado solo por el `font-size`
   del glyph. Después de 2 ajustes en vivo con el usuario, quedó en
   contenedor 20px / glyph 16px (subido gradualmente desde 16px/12px
   hasta que confirmó "listo").

Mismas 2 ubicaciones que el fix de arriba (`.pc-sidebar-flyout
.pc-nav-icon` fuera del media query + su copia `!important` dentro del
breakpoint móvil, por la misma razón defensiva ya documentada ahí).
