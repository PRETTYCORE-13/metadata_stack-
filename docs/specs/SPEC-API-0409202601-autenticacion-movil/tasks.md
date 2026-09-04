# SPEC-API-0409202601 — Autenticación móvil (Flutter) contra usuarios de metadata_stack

**Documento:** Tasks · **Fase:** ✅ aprobada (2026-09-04), ejecución en
curso. Cada tarea es chica y verificable por sí sola (compila, corre,
o un test pasa) — se ejecutan en orden, una por vez. Marcar `[x]` a
medida que se completan.

## Grupo A — Modelo de datos

1. [ ] **Migración**: crear `meta_schema_usuario_sesion_movil` (`refresh_token_hash :binary`, `etiqueta_dispositivo :string` nullable, `ultimo_uso_en :utc_datetime` nullable, `usuario_id` FK a `meta_schema_usuario`, `inserted_at`) — índice único en `refresh_token_hash`, índice en `usuario_id` — design.md §2.
2. [ ] **Schema** `MetadataApp.Autenticacion.SesionMovil` (`lib/metadata_app/autenticacion/sesion_movil.ex`) — sin changeset público, se construye siempre desde el contexto (§B), mismo criterio que `UsuarioToken`.
3. [ ] **Verificar**: `mix ecto.migrate` limpio, `mix compile --warning-as-errors` limpio.

## Grupo B — Contexto: emisión/verificación/revocación de sesiones

4. [ ] **`Autenticacion.crear_sesion_movil(usuario, etiqueta_dispositivo)`** — genera refresh token (`:crypto.strong_rand_bytes(32)` + hash, mismo patrón que `UsuarioToken.build_hashed_token/3`), inserta la fila, devuelve `{refresh_token_crudo, %SesionMovil{}}` — design.md §2.
5. [ ] **`Autenticacion.obtener_sesion_movil_valida(refresh_token_crudo)`** — hashea, busca por `refresh_token_hash` con `where: inserted_at > ago(60, "day")` (mismo patrón que `UsuarioToken.verify_session_token_query/1`) — devuelve `{:ok, sesion}` o `:error` — design.md §2 (validación de vigencia).
6. [ ] **`Autenticacion.tocar_sesion_movil(sesion)`** — actualiza `ultimo_uso_en` a `DateTime.utc_now/0` — llamado solo desde renovación (R3), no desde cada request — design.md §1.3 nota.
7. [ ] **`Autenticacion.revocar_sesion_movil(sesion_o_id)`** — `Repo.delete`, idempotente si ya no existe — design.md §2.
8. [ ] **`Autenticacion.listar_sesiones_movil(usuario)`** — todas las `SesionMovil` de ese usuario, orden por `ultimo_uso_en desc nulls last` — para R7.
9. [ ] **Verificar**: cada función probada desde `iex`/`mix run -e` contra Postgres real (regla del skill `spec`, no alcanza con "compila") — crear una sesión, confirmar que aparece en `listar_sesiones_movil`, revocarla, confirmar que `obtener_sesion_movil_valida` ya no la encuentra.

## Grupo C — Access token + plug de autenticación

10. [ ] **`Autenticacion.emitir_access_token(sesion_movil)`** — `Phoenix.Token.sign(MetadataAppWeb.Endpoint, "movil access", %{usuario_id: ..., sesion_movil_id: ...})` — design.md §1.1.
11. [ ] **`MetadataAppWeb.ApiMovilAuth`** (plug, `lib/metadata_app_web/api_movil_auth.ex`) — lee `Authorization: Bearer`, `Phoenix.Token.verify/4` con `max_age: 7200`, si válido busca `SesionMovil` por `sesion_movil_id` (reusa `Repo.get` directo, no `obtener_sesion_movil_valida/1` — esa es para el refresh token, un id distinto), arma `current_scope` vía `Scope.for_usuario/1` — 401 `{"error": "no_autenticado"}` en cualquier fallo — design.md §1.3.
12. [ ] **Verificar**: token real emitido con `emitir_access_token/1`, `Phoenix.Token.verify/4` lo acepta; token con `sesion_movil_id` de una sesión ya borrada, el plug lo rechaza.

## Grupo D — Rate limiting (R10/R11)

13. [ ] **`MetadataApp.Autenticacion.LimiteIntentos`** (GenServer + `:ets`, `lib/metadata_app/autenticacion/limite_intentos.ex`) — `registrar_intento_fallido(email)`, `limpiar(email)`, `bloqueado?(email)` (5 en 15 min, ventana deslizante simple) — design.md §3.
14. [ ] Agregar a la supervision tree (`lib/metadata_app/application.ex`).
15. [ ] **Verificar**: 5 llamadas a `registrar_intento_fallido/1` seguidas de `bloqueado?/1` → `true`; `limpiar/1` lo resetea.

## Grupo E — Endpoints (router + controller)

16. [ ] **Router**: pipelines `:api_movil`/`:api_movil_auth` + `scope "/api/movil"` con las rutas de §4 — design.md §1.2.
17. [ ] **`MetadataAppWeb.Api.Movil.SesionController`** (`lib/metadata_app_web/controllers/api/movil/sesion_controller.ex`):
    - `verificar/2` (R11) — `LimiteIntentos.bloqueado?/1` primero (429 si sí), busca `Usuario` por email, si existe resuelve empresa (mismo camino que R9) y devuelve `existe: true` + empresa; si no, `registrar_intento_fallido/1` + 404.
    - `create/2` (login, R1/R2) — `LimiteIntentos.bloqueado?/1` primero, `Autenticacion.get_usuario_by_email_and_password/2`, si válido limpia el contador + `crear_sesion_movil/2` + `emitir_access_token/1` + resuelve empresa (R9), si inválido `registrar_intento_fallido/1` + 401.
    - `refrescar/2` (R3/R4) — `obtener_sesion_movil_valida/1`, si ok `tocar_sesion_movil/1` + `emitir_access_token/1`, si no 401.
    - `delete/2` (logout, R8) — `revocar_sesion_movil/1` por el refresh token del body, 204 siempre.
18. [ ] **Verificar con `curl`/`httpie` real contra el servidor de dev** (no solo tests) los 4 endpoints con: credenciales válidas, inválidas, refresh token válido/vencido/revocado, y el límite de intentos disparando un 429 real al 6to intento — regla del skill `spec` (verificación real, no solo `mix test`).

## Grupo F — Panel web: ver/revocar sesiones (R7)

19. [ ] **`MetadataAppWeb.Sysadmin.SesionesMovilLive`** (`lib/metadata_app_web/live/sysadmin/sesiones_movil_live.ex`) — lista `listar_sesiones_movil/1` del usuario logueado (`current_scope.usuario`), columnas etiqueta/creada/último uso, botón "Cerrar sesión" por fila → `revocar_sesion_movil/1` + refresca la lista.
20. [ ] **Ruta + entrada de nav** en Sysadmin (mismo patrón que Credenciales/Ambientes — permiso propio o reusa uno existente, a definir al codear según lo que ya exponga `Permissions.capacidades_sysadmin/0`).
21. [ ] **Verificar en el navegador**: crear una sesión móvil real (vía `curl` a `/login`), confirmar que aparece en la pantalla, revocarla desde ahí, confirmar con `obtener_sesion_movil_valida/1` que ya no es válida.

## Grupo G — Cierre

22. [ ] **`mix compile --warning-as-errors`**, **`mix credo.alcance`**, **`mix test`** — suite completa sin failures nuevos.
23. [ ] **Documento final**: actualizar `docs/specs/README.md` §"Features documentadas acá" con esta spec (mismo formato que la entrada de folios).
24. [ ] **Handoff a Flutter**: el contrato de `design.md` §4 queda listo para pasarle a la IA que trabaja el repo Flutter — nada de este grupo toca ese repo.
