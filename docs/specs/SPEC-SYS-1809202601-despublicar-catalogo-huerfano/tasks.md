# Tasks — Despublicar un catálogo huérfano de un ambiente

Cada tarea es chica y verificable por sí sola antes de pasar a la
siguiente. Se implementa con "seguí tasks.md, tarea N".

## Grupo A — Generar la migración de DROP sin header local (R1, R3, R5)

- [ ] **A1.** `CatalogoGenerador.generar_migracion_drop/1` (pública) --
      se extrae el cuerpo de la `crear_migracion_drop/1` privada tal
      cual (sin exigir un header local), `eliminar/4` pasa a llamarla
      en vez de tener su propia copia. Verificable: `mix test`
      sobre los tests existentes de `CatalogoGenerador.eliminar/4`
      sigue pasando igual (mismo comportamiento, solo reorganizado).

- [ ] **A2.** `mix motor.generar_drop_huerfano <catalogo>
      --confirmar=<catalogo>` -- rechaza si el catálogo existe local
      (apunta a "BC List → Eliminar"), rechaza si `--confirmar` no
      coincide con `<catalogo>`, si no genera la migración y la corre
      local ya mismo. Verificable: correrlo con `--confirmar` que NO
      coincide da error sin tocar nada; con el nombre correcto sobre
      un catálogo inexistente local, escribe la migración en
      `priv/repo/migrations/` y la aplica sin error.

## Grupo B — Verificación real con el caso que motivó esto

- [ ] **B1.** Generar la migración para `historico`:
      ```
      mix motor.generar_drop_huerfano historico --confirmar=historico
      ```
      Confirmar que corre limpio en local (no hay tabla `historico`
      física local que romper, o si la hay, que se dropea sin error).

- [ ] **B2.** Propagar a `unstable`, reusando `motor.despublicar` SIN
      NINGÚN CAMBIO:
      ```
      mix motor.despublicar --sistema=unstable historico
      ```
      Verificar en `unstable`: la tabla física `historico` y su header
      desaparecen, `/historico` deja de dar `Ecto.MultipleResultsError`
      y navega a `pty_h_historico` sin ambigüedad.

- [ ] **B3.** Commitear la migración generada a git (no es `pty_*`, no
      está gitignored) -- así llega a `testing`/`stable` por promoción
      normal, no solo a `unstable`.

- [ ] **B4.** Suite completa (`mix test`) sin regresiones.
