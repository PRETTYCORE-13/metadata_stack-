# SPEC-SYS-1109202602 — BC Motor: Tab Diagrama

**Documento:** Tasks · **Fase:** ✅ documentación retroactiva verificada + 1 fix real (R10).

## Grupo A — Verificación retroactiva (R1-R9) ✅

1. [x] R1 (visibilidad del tab) verificado: `unless(@es_detalle?, ...)`
   en la lista de tabs, `bc_motor_live.ex:2036-2043`.
2. [x] R2-R6 (generación de la definición) verificados contra
   `diagrama_mermaid/2`, `escapar_mermaid/1`, `estilo_color/2`,
   `color_texto_legible/1` (`bc_motor_live.ex:2154-2210`).
3. [x] R7-R9 (renderizado) verificados contra `cargarMermaid()` +
   `DiagramaMotor.pintar()` en `assets/js/app.js`, y
   `priv/static/vendor/mermaid.min.js` (vendorizado, sin CDN).

## Grupo B — Fix real: refresco en vivo (R10) ✅

4. [x] `requirements.md`/`design.md` escritos PRIMERO documentando el
   bug tal como estaba (sin `updated()`) — recién después se tocó
   código, mismo orden que toda spec de este proyecto.
5. [x] `DiagramaMotor` (`assets/js/app.js`) — agregado `updated()`
   (llama a `pintar()`) + guard `definicion === this.definicionPintada`
   en `pintar()` para no re-renderizar Mermaid en cada `updated()`
   que no toque este `<div>`.
6. [x] `mix esbuild metadata_app` — bundle regenerado sin errores
   (`app.js`, 485.2kb).
7. [ ] **Verificación interactiva en navegador pendiente** (mismo
   límite ya documentado en otras specs de este proyecto — sin
   navegador headless disponible en este entorno): confirmar en vivo
   que editar una transición con el tab Diagrama abierto (o
   volviendo a él sin F5) redibuja el grafo con el cambio nuevo, sin
   parpadeo ni doble-render perceptible. Queda para la próxima vez
   que se abra el BC Motor de un catálogo real.

## Nota

Ningún cambio de este Grupo B toca `bc_motor_live.ex` ni el resto del
servidor — `@diagrama` ya se recalculaba correctamente en cada
`cargar_motor/1` desde antes de esta spec; el fix es 100% del lado
del hook JS (el cliente no reaccionaba a un dato que el servidor ya
mandaba bien).
