---
name: spec
description: Cómo ejecutar trabajo SDD-anchored (requirements→design→tasks) en docs/specs/ de este proyecto. Usar cuando el usuario pide arrancar o continuar una spec, dice "seguí tasks.md"/"continuemos el spec", o cuando se va a implementar algo dentro de una carpeta docs/specs/SPEC-*.
---

# SDD anchored — cómo ejecutar

La metodología completa (las 3 fases, notación EARS, convención de
nombres `SPEC-<ÁREA>-<DDMMAAAA><secuencia>-<slug-corto>`) vive en
`docs/specs/README.md` — leerlo si es la primera vez en la sesión.
Esto de acá es el checklist de EJECUCIÓN: cómo comportarse en cada
paso, no qué es SDD.

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
- Si algo ya decidido (memoria, un `design.md` ya aprobado) queda en
  duda por un hallazgo nuevo, se vuelve a `requirements.md`/`design.md`
  a corregirlo ANTES de seguir — nunca construir sobre una base que ya
  se sabe rota.

## 2. Fases — ejecutar, mostrar, esperar

Cada fase (`requirements.md` → `design.md` → `tasks.md`) se arma en
colaboración directa con el usuario, sección por sección cuando está
aprendiendo o decidiendo algo no trivial — nunca las tres fases de una
sentada sin pausa. Excepción: el usuario puede pedir explícitamente
"continuá con todas" para `tasks.md` una vez aprobado — eso NO aplica
a `requirements.md`/`design.md`, esas siguen aprobándose antes de
escribirse.

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
cerrado el último grupo de tasks): documentarlo en `requirements.md`
primero (requisito nuevo numerado, con fecha y "a pedido explícito" si
vino del usuario), después `design.md` si hace falta una decisión
técnica nueva, recién DESPUÉS tocar `tasks.md`/código. El spec nunca
queda desactualizado respecto al código real — es la fuente de verdad,
no una foto del día que se aprobó.
