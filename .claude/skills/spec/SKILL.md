---
name: spec
description: Cómo ejecutar trabajo SDD-anchored (requirements→design→tasks) en docs/specs/ de este proyecto. Usar cuando el usuario pide arrancar o continuar una spec, dice "seguí tasks.md"/"continuemos el spec", o cuando se va a implementar algo dentro de una carpeta docs/specs/SPEC-*.
---

# SDD anchored — cómo ejecutar

La metodología completa (las 5 fases, notación EARS, convención de
nombres `SPEC-<ÁREA>-<DDMMAAAA><secuencia>-<slug-corto>`) vive en
`docs/specs/README.md` — leerlo si es la primera vez en la sesión.
Esto de acá es el checklist de EJECUCIÓN: cómo comportarse en cada
paso, no qué es SDD.

Al arrancar una spec nueva, `00.doc_human.md` es el primer archivo que
se escribe — antes que `01.requirements.md`. Es la explicación 100% en
lenguaje llano (sin EARS, sin tablas ni módulos) que sirve para
capacitar desarrolladores nuevos, gente de ADN o asesores de servicio a
cliente, y para que cualquiera entienda la spec sin tener que pedirle a
la IA que la resuma.

**Antes de volver a explicar cómo usar algo ya implementado**, revisar
primero si `05.usage.md` ya lo cubre — si sí, usarlo tal cual en vez de
rearmar la explicación de cero; si no está o quedó desactualizado
respecto al código real, esa es la señal de escribirlo/corregirlo
ahora, y recién después responder con esa versión. Nunca explicar de
memoria una funcionalidad ya construida sin dejar la explicación
asentada ahí — la próxima sesión (de este usuario o de otra IA) vuelve
a pagar el mismo costo si no queda escrita.

## 1. No asumir nada (regla #1, sin excepción)

Antes de crear, nombrar, o afirmar cualquier cosa sobre el sistema,
verificar contra la realidad — nunca asumir:

- **¿Ya existe?** Antes de crear una entidad nueva (rol, catálogo,
  permiso, campo, tabla, carpeta de nav) buscarla primero (`grep`,
  consulta directa a la DB, `Repo.get_by`). Un nombre "obvio" casi
  seguro ya está usado por algo real. Caso real (2026-09-01, ver
  `feedback_roles_sistema_ad_hoc` en memoria): se creó un rol de
  sistema "pty-funcional-admin" sin verificar que ya existía un rol de
  EMPRESA con ese mismo nombre, con usuarios reales y ~200 permisos —
  quedaron dos filas duplicadas, el usuario lo detectó como
  "inconsistencia que causará desorden".
- **¿Cuál es la forma real?** Antes de escribir un changeset/query
  contra un schema, leerlo — no inferir campos por el nombre de la
  tabla ni por lo que "debería" tener.
- **¿Qué dice el código AHORA, no la memoria?** Un recuerdo de una
  sesión anterior es una foto vieja — releer el archivo actual antes
  de actuar sobre lo que dice, sobre todo si el dato es un nombre de
  función, un índice, o un módulo que otra parte del código podría
  haber tocado después.
- **Ante una bifurcación real** (2+ opciones razonables, ninguna
  obviamente correcta): `AskUserQuestion`, nunca elegir en silencio.
  Ejemplos de esta spec donde una pregunta cambió el resultado: si
  Subtipo necesitaba "Tipo de transacción" como campo propio, y si la
  regla de nombre único de rol debía ser global o solo sistema-vs-
  empresa.
- Si algo ya decidido (memoria, un `02.design.md` ya aprobado) queda en
  duda por un hallazgo nuevo, se vuelve a
  `01.requirements.md`/`02.design.md` a corregirlo ANTES de seguir —
  nunca construir sobre una base que ya se sabe rota.

## 2. Fases — ejecutar, mostrar, esperar

Cada fase (`01.requirements.md` → `02.design.md` → `03.tasks.md`) se
arma en colaboración directa con el usuario, sección por sección cuando
está aprendiendo o decidiendo algo no trivial — nunca las tres fases de
una sentada sin pausa. Excepción: el usuario puede pedir explícitamente
"continuá con todas" para `03.tasks.md` una vez aprobado — eso NO
aplica a `01.requirements.md`/`02.design.md`, esas siguen aprobándose
antes de escribirse.

## 3. Verificación real, no solo `mix test`

- Los tests son necesarios pero no alcanzan — probar contra Postgres
  real cuando el cambio toca datos/config que no nace de una migración
  (roles, permisos, headers, estados, catálogos de sistema).
- Toda escritura de verificación contra `dev` que NO deba persistir:
  envolver en `Repo.transaction(fn -> ... Repo.rollback(...) end)` y
  confirmar después por consulta directa (`psql`) que no quedó
  residuo — nunca dejar datos de prueba en la DB compartida de dev.
- Un cambio de datos de APLICACIÓN (roles, permisos, headers, estados
  — a diferencia de una migración de tabla) tiene que replicarse en
  `dev` Y `test` por separado; no asumir que una corrida alcanza para
  las dos bases.
- `CatalogoGenerador.generar/1` sobre un catálogo cuyo `.ex` ya existe
  en el filesystem (compartido entre dev/test) toma la rama de
  retrofit — si la tabla física todavía no existe en la base que se
  está tocando, falla. Correr `mix ecto.migrate` directo primero en
  esa base antes de re-ejecutar el generador ahí.

## 4. Mantener el spec vivo

Si aparece un caso no contemplado durante la implementación (ej. R8 en
`SPEC-SYS-0109202601-administrador-folios`, agregado después de
cerrado el último grupo de tasks): documentarlo en
`01.requirements.md` primero (requisito nuevo numerado, con fecha y "a
pedido explícito" si vino del usuario), después `02.design.md` si hace
falta una decisión técnica nueva, recién DESPUÉS tocar
`03.tasks.md`/código. El spec nunca queda desactualizado respecto al
código real — es la fuente de verdad, no una foto del día que se
aprobó.

`00.doc_human.md` casi nunca necesita tocarse en este ciclo — es
conceptual, no técnico. Solo se actualiza si el requisito nuevo cambia
el PROPÓSITO o el ALCANCE de la spec vistos por alguien no técnico
(no por cada detalle nuevo de `01.requirements.md`/`02.design.md`).

## 5. Cerrar un grupo de `03.tasks.md` con `05.usage.md`

Cuando un grupo de `03.tasks.md` queda ✅ cerrado y verificado en real
(regla #3) Y tiene interacción visible para algún usuario (pantalla,
comando de terminal, botón) — escribir o actualizar `05.usage.md` con
esa funcionalidad ANTES de dar el grupo por terminado. Un grupo sin
interacción visible (un detector interno, una guarda que corre sola
sin acción propia) no genera entrada ahí.

`05.usage.md` se arma **solo con lo que ya está construido y
verificado** — nunca con lo que `01.requirements.md`/`02.design.md`
todavía describen pero `03.tasks.md` no cerró. Usa únicamente
información real de la spec (requisitos, decisiones de diseño,
verificaciones reales ya documentadas en `03.tasks.md`) y del código —
nunca inventa pantallas, botones ni comportamiento no confirmado. Si
al escribirlo aparece una contradicción entre lo que dice
`02.design.md`/`03.tasks.md` y lo que el código hace de verdad,
repórtala antes de resolverla por cuenta propia (mismo criterio de la
regla #1, "no asumir").

No duplica: si algo es una decisión técnica de CÓMO se construyó, va
en `02.design.md`, no en `05.usage.md` (que solo referencia, ej. "ver
R6"); si algo es un requisito de QUÉ debe hacer el sistema, va en
`01.requirements.md`.
