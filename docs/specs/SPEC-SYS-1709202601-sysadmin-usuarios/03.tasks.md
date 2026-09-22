# SPEC-SYS-1709202601 — Sysadmin / Administrador de usuarios

**Documento:** Tasks · **Fase:** ✅ completa (2026-09-17) — Grupos A-E,
código + tests + suite completa (622 tests) pasando.

Este `tasks.md` cubre exclusivamente los incrementos reales sobre la
pantalla, no la spec completa (que es documentación retroactiva de lo
ya implementado — ver `README.md` de `docs/specs/`): Grupos A-C =
"Eliminación total de usuario" (R13a-e, `design.md` §10); Grupos D-E =
"Picker de doble lista para Roles" + sus 3 ajustes UX (R14-R16f,
`design.md` §4).

## Grupo A — Handler + botón en el LiveView ✅

- [x] A1. `handle_event("eliminar_usuario", ...)` en
      `UsuariosEmpresaLive`: guardas R13c (no auto-eliminación) y R13d
      (no `super_admin`) del lado servidor, después
      `Autenticacion.eliminar_usuario/1`, después el mismo reset de
      `cerrar_detalle/2` + `cargar_usuarios/1` (R13e).
- [x] A2. Botón "Eliminar usuario" en la pestaña Generales (junto a
      "Cerrar todas las sesiones"), con `data-confirm` explícito
      (R13b) y `:if` que lo oculta si el usuario seleccionado es uno
      mismo o es `super_admin` (R13c/R13d).

## Grupo B — Tests ✅

- [x] B1. Test: eliminar un usuario de una sola empresa lo borra por
      completo (desaparece de la lista, `Repo.get(Usuario, id) ==
      nil`).
- [x] B2. Test: eliminar un usuario que pertenece a VARIAS empresas lo
      borra de todas (R13a) — sin ninguna fila huérfana en
      `usuario_rol`/`usuario_empresa`/`usuario_branch` para ese id.
- [x] B3. Test: el botón no se renderiza y el evento no tiene efecto
      si `usuario_id == current_scope.usuario.id` (R13c).
- [x] B4. Test: el botón no se renderiza y el evento no tiene efecto
      sobre un usuario `super_admin` (R13d).

## Grupo C — Verificación real (no solo `mix test`) ✅

- [x] C0. `mix test test/metadata_app_web/live/sysadmin/usuarios_empresa_live_test.exs`
      corrido dentro de `devcontainer-app-1` (`docker exec`, la app
      corre en un devcontainer — `mix` no vive en el host Windows, solo
      adentro del contenedor) — **14 tests, 0 failures**. La primera
      corrida encontró 1 falla real (en el test nuevo, no en el
      código): `refute html =~ objetivo.email` fallaba porque el flash
      de confirmación repite el email a propósito — corregido el
      assert para chequear la ausencia del renglón de la lista en vez
      del email suelto.
- [x] C1. Contra Postgres real de dev (`devcontainer-db-1`, NO la base
      de test), vía `mix run` en un script temporal (borrado después)
      dentro de un `Repo.transaction` con `Repo.rollback/1` forzado:
      usuario de prueba en 2 empresas + 2 roles (administrador de cada
      una) + 1 branch + 1 sales_unit + 1 inventory_location →
      `Autenticacion.eliminar_usuario/1` → confirmado ANTES `{2, 2, 1,
      1, 1}` filas dependientes, DESPUÉS `{0, 0, 0, 0, 0}` y
      `Repo.get(Usuario, id) == nil`, TODO dentro de la misma
      transacción. Confirmado por `psql` directo después del rollback
      que no quedó ningún residuo (`count = 0` sobre el email de
      prueba).

## Grupo D — Picker de doble lista para Roles (R14-R16c) ✅

- [x] D1. Reemplazado `busqueda_rol`/`roles_busqueda_resultado` por
      `roles_disponibles` (`Permissions.listar_roles(empresa.id, true)`
      menos los ya concedidos, `incluir_sysadmin?: true` a propósito —
      ver `design.md` §4) + `rol_disponible_seleccionado_id` +
      `rol_concedido_seleccionado_id`, en `mount/3`, los 4 puntos de
      reset (`cambiar_empresa_en_foco`, `cerrar_detalle`,
      `eliminar_usuario`, `quitar_empresa_de_usuario`) y
      `cargar_detalle_usuario/1`.
- [x] D2. Handlers `seleccionar_rol_disponible`,
      `seleccionar_rol_concedido`, `mover_rol_a_concedidos`,
      `mover_rol_a_disponibles` (guard `if id` contra flecha sin
      selección) — reemplazan `buscar_rol`/`agregar_rol_a_usuario`/
      `quitar_rol_de_usuario` (confirmado sin otras referencias en
      `lib/` ni `test/` antes de borrarlos).
- [x] D3. Render: 2 `<ul>` con `<li phx-click="seleccionar_rol_*">`
      (resaltado si coincide con el `*_seleccionado_id`) + 2 botones de
      flecha (`disabled` sin selección) entre ambas listas + 1
      `<input>` de filtro por lista.
- [x] D4. Hook JS `FiltrarListaRoles` agregado a `assets/js/app.js`
      (junto a `FiltroMenu`/`CopiarRuta`, mismo archivo — no existe una
      convención de separar hooks en otro archivo en este proyecto) y
      registrado en la lista de `hooks` del `LiveSocket`. Monta en cada
      `<ul>` (no en el `<input>`), lee el input hermano por
      `data-input-id`, reaplica el filtro en `updated()`.
- [x] D5. 3 tests nuevos: mover con "→" concede de verdad
      (`Permissions.roles_de_usuario/2` antes/después + el HTML pasa de
      un lado al otro), mover con "←" revoca de verdad, un click de
      flecha SIN selección no concede ni revoca nada.
- [x] D6. Suite completa corrida dentro de `devcontainer-app-1` —
      **619 tests (5 properties), 0 failures**. El archivo de este
      LiveView solo: 17 tests, 0 failures.

## Grupo E — Ajustes UX del picker de Roles (R16d-f) ✅

- [x] E1. Altura auto-ajustable (R16d): la fila de las 2 listas pasa a
      `style="height: 70vh"` + `items-stretch` (mismo patrón que la
      lista maestra de usuarios de la izquierda de la pantalla), cada
      columna a `flex flex-col`, cada `<ul>` de `h-56 overflow-y-auto`
      fijo a `flex-1 min-h-0 overflow-y-auto`.
- [x] E2. Botón "Quitar todos" (R16e) junto al label "Asignados" —
      handler `quitar_todos_los_roles` (recorre `roles_concedidos`,
      `Permissions.revocar_rol/3` por cada uno), `disabled` si no hay
      roles, `data-confirm` explícito (mismo criterio que el resto de
      acciones destructivas de la pantalla).
- [x] E3. Auto-foco en el primer disponible tras asignar (R16f):
      `mover_rol_a_concedidos` ya no limpia la selección a `nil` — toma
      el primer id de `roles_disponibles` YA recalculado (sin el rol
      recién movido), permitiendo click "→" repetido sin reseleccionar.
- [x] E4. 3 tests nuevos: "Quitar todos" revoca todo de una vez; el
      botón sale `disabled` sin roles; clickear "→" dos veces seguidas
      (sin reseleccionar en el medio) asigna 2 roles distintos. La
      primera corrida de este último test falló por un supuesto propio
      erróneo (esperaba "Sin roles disponibles." tras vaciar la lista,
      mostraba una lista vacía) — el rol global "administrador"
      (`empresa_id: nil`, sembrado por `seed_roles_sistema` desde
      2026-07-25) SIEMPRE queda disponible salvo que se lo asignen
      explícitamente; corregido el assert.
- [x] E5. Suite completa corrida dentro de `devcontainer-app-1` —
      **622 tests (5 properties), 0 failures**. El archivo de este
      LiveView solo: 20 tests, 0 failures.
