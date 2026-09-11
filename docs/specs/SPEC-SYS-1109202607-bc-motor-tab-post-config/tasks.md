# SPEC-SYS-1109202607 — BC Motor: Tab Post Config

**Documento:** Tasks · **Fase:** ✅ documentación retroactiva verificada + 1 fix real (R6a).

## Grupo A — Montaje e integración ✅

1. [x] R1/R2 verificados: "postview" en el bloque incondicional de
   tabs, `live_render/3` con `session: %{"nombre" => ...}`, dos
   cláusulas de `mount/3` en `PlantillaConstructorLive`.

## Grupo B — Propósito y estado ✅

2. [x] R3/R4 verificados: `nueva_plantilla` vs.
   `nueva_plantilla_impresion`, optgroups por `proposito`.
3. [x] R5/R6 verificados contra `recargar_estado/2` — a lo sumo una
   publicada por propósito.

## Grupo C — Multi-vista, guardar/publicar, conflicto ✅

4. [x] R7 verificado: `alternar_disponible_multi_vista`, independiente
   de `estado`.
5. [x] R8-R10 verificados contra `plantilla_desactualizada?/1`
   (compara `update_guid`), `handle_event("guardar"/"publicar"/"recargar_plantilla", ...)`.

## Grupo D — Utilidades ✅

6. [x] R11 verificado: `registro_muestra_id` + hook `AbrirVistaPrevia`
   (apertura síncrona de pestaña antes del round-trip, evita bloqueo
   de pop-up).
7. [x] R12 verificado: `regenerar_automatica` →
   `MetaPlantillas.regenerar_plantilla_automatica/1`, nunca cambia la
   publicada.

## Grupo E — Fix real: Folio en la paleta ✅

8. [x] Verificado que `FichaLive.nodo_plantilla_render/1` (tipo
   "campo") ya soportaba `"folio"` (`@claves_campos_control`,
   `valor_legible_control/4`) antes de tocar nada.
9. [x] Agregado `%{clave: "folio", etiqueta: "Folio", requiere_alcance?: false}`
   a `@campos_control` de `plantilla_constructor_live.ex`, mismo
   lugar/orden que la versión de `bc_motor_live.ex`.
10. [x] `mix compile --force` limpio (dev y test), `mix test`: 517
    tests, 0 failures. Servidor recompilado.

## Nota — cierre del módulo BC Motor (primer barrido)

Con esta spec quedan documentados los 7 tabs principales del BC
Motor: Configuración, Diagrama, Contrato, Reglas, Permisos y Alcance
de Datos, Get Config, Post Config — 3 fixes reales encontrados y
corregidos en el camino (refresco del Diagrama, código muerto del
modo "rango", Folio faltante en la paleta del Constructor). Quedan
fuera, mencionados pero no especificados: el editor de grid interno
del Constructor, el tab "Importación" (`ImportacionConstructorLive`)
y el uso standalone de `CatalogoPermisosLive` — candidatos a specs
propias si hacen falta más adelante.
