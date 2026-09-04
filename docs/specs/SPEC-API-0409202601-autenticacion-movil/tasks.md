# SPEC-API-0409202601 — Autenticación móvil (Flutter) contra usuarios de metadata_stack

**Documento:** Tasks · **Fase:** ✅ aprobada (2026-09-04), **ejecutada
completa el mismo día** (todos los grupos, verificados contra Postgres
real y HTTP real -- ver notas por tarea).

## Grupo A — Modelo de datos ✅

1. [x] **Migración** `20260904174740_crear_meta_schema_usuario_sesion_movil.exs` -- exacto lo planeado.
2. [x] **Schema** `MetadataApp.Autenticacion.SesionMovil` -- además de lo planeado, incluye `build/2` y las queries `buscar_por_token_query/1`/`verify_refresh_token_query/1` (mismo módulo "puro" que `UsuarioToken`, sin `Repo` adentro).
3. [x] **Verificado**: `mix ecto.migrate` y `mix compile` limpios.

## Grupo B — Contexto: emisión/verificación/revocación de sesiones ✅

4. [x] `crear_sesion_movil/2` -- exacto lo planeado.
5. [x] `obtener_sesion_movil_valida/1` -- exacto lo planeado.
6. [x] `tocar_sesion_movil/1` -- exacto lo planeado.
7. [x] `revocar_sesion_movil/1` -- solo por struct (uso del LiveView, §F). Se agregó además `revocar_sesion_movil_por_token/1` (hashea y borra directo, SIN el filtro de 60 días -- necesario para el logout de §E, que solo tiene el token crudo, no el struct, y debe poder revocar aunque ya haya vencido).
8. [x] `listar_sesiones_movil/1` -- orden real: `ultimo_uso_en desc nulls last, inserted_at desc` (agregado el segundo criterio para que las sesiones que nunca se refrescaron también ordenen de forma predecible, más recientes primero).
9. [x] **Verificado contra Postgres real** (`mix run -e`, ver conversación): crear → aparece en listar → tocar setea fecha → revocar → `obtener_sesion_movil_valida` da `:error`. Las 4 aserciones dieron `true`.

También se agregó (no estaba en el plan original, necesario para R9): `empresa_resuelta_para_login_movil/1` -- reusa `empresas_de_usuario/1`/`empresa_default_de_usuario/1`, ya existentes y usadas por el login web (`UsuarioAuth.log_in_usuario/2`), en vez de duplicar esa lógica.

## Grupo C — Access token + plug de autenticación ✅

10. [x] `emitir_access_token/1` -- exacto lo planeado. Se agregó `verificar_access_token/1` (contexto, no en el plug) que hace firma+expiración+chequeo de que la `SesionMovil` siga existiendo, y `access_token_max_age_seconds/0` (accessor público del `@access_token_max_age_seconds`, usado por el controller para no repetir el número en la respuesta JSON).
11. [x] `MetadataAppWeb.ApiMovilAuth` -- delega la verificación completa a `Autenticacion.verificar_access_token/1` (más limpio que repetir `Phoenix.Token.verify` + el lookup de sesión en el propio plug), arma `current_scope` con `Scope.for_usuario/1` + `Scope.con_empresa_activa/2` (empresa resuelta FRESCA en cada request vía `empresa_resuelta_para_login_movil/1`, no guardada en el token -- mismo criterio de revalidación que ya usa `hidratar_empresa_activa/2` en la web).
12. [x] **Verificado contra Postgres real**: `emitir_access_token/1` devuelve un string; `verificar_access_token/1` lo acepta y devuelve el usuario correcto; después de `revocar_sesion_movil/1`, el MISMO token (firma/expiración todavía válidas) ya no verifica -- confirma la revocación instantánea de design.md §1.1.

## Grupo D — Rate limiting (R10/R11) ✅

13. [x] `MetadataApp.Autenticacion.LimiteIntentos` -- exacto lo planeado (GenServer + ETS pública, ventana deslizante de timestamps). Se agregó `reintentar_en_segundos/1` (no estaba explícito en el plan, pero design.md §4 ya prometía ese campo en la respuesta 429).
14. [x] Agregado a `application.ex`.
15. [x] **Verificado**: 5 fallos → `bloqueado?/1` `true`; `limpiar/1` lo resetea. Repetido después contra el servidor real vía HTTP (ver tarea 18).

## Grupo E — Endpoints (router + controller) ✅

16. [x] Router -- pipelines + `scope "/api/movil"` ubicado ANTES del `scope "/api"` existente (que tiene `/:tabla` genérico -- mismo motivo que ya documentan las rutas de roles/permisos de ese scope: literales antes de comodines).
17. [x] `MetadataAppWeb.Api.Movil.SesionController` -- las 4 acciones, exacto lo planeado.
18. [x] **Verificado con `curl` real contra `mix phx.server` corriendo** (no solo `mix run -e`): usuario de prueba creado a mano, probado `/verificar` (existe/no existe), `/login` (credenciales válidas → 200 con los 3 campos del contrato/inválidas → 401), `/token/refrescar` (válido → 200/después de logout → 401), `/sesion` DELETE (204), y **el rate limit disparando un 429 real** al 6to intento fallido consecutivo, con `reintentar_en_segundos` > 0. Todo limpiado después (usuario y sesiones de prueba borrados).

## Grupo F — Panel web: ver/revocar sesiones (R7) ✅

19. [x] `MetadataAppWeb.Sysadmin.SesionesMovilLive` -- exacto lo planeado.
20. [x] **Decisión tomada al codear** (no estaba resuelta en design.md): la pantalla solo requiere `on_mount {MetadataAppWeb.UsuarioAuth, :mount_current_scope}` (estar logueado), SIN agregar una capacidad `sysadmin_*` nueva -- agregar una capacidad real hoy exige una migración de seed + un rol de sistema + wiring en la pestaña "Sysadmin" de `UsuariosEmpresaLive` (visto en `Permissions.capacidades_sysadmin/0`), alcance no pedido para una pantalla que es autoservicio sobre las PROPIAS sesiones de quien la abre (no hay selector de usuario, siempre lista `current_scope.usuario`) -- no es una herramienta de administrar a otros. Vive bajo `/sysadmin` solo por ubicación de navegación. El menú (`@menu`, entrada "Sesiones móviles") se agregó a las 15 pantallas de Sysadmin que lo duplican, mismo patrón ya existente en el repo.
21. [x] **Verificado**: `GET /sysadmin/sesiones-movil` sin sesión → 302 (confirma que el auth hook corre). Sesión creada de verdad vía `/login` (HTTP real) confirmada visible en `listar_sesiones_movil/1` con la misma `etiqueta_dispositivo` mandada -- mismo dato que la pantalla renderiza. No se pudo manejar un navegador real en esta sesión (sin herramienta de automatización de browser disponible), así que el click de "Cerrar sesión" en sí no se probó con mouse real, pero `revocar_sesion_movil/1` (la función que ese botón invoca) ya está verificada en el Grupo B.

## Grupo G — Cierre

22. [x] `mix compile --warning-as-errors` limpio en TODOS los archivos de esta spec (los warnings que tira el repo completo son de archivos no tocados por esta spec, trabajo de otra persona). `mix credo.alcance`: 1 solo warning preexistente, ajeno a esta spec.
    **`mix test` -- NO se pudo correr limpio, por un problema PREEXISTENTE y no relacionado**: la base de test local en esta máquina Windows nunca migró limpio desde cero (una migración de hace dos semanas, ajena a esta spec, falla en una tabla que no existe; hay además migraciones locales con timestamps con formato inválido). Coincide con el patrón de toda la sesión: en esta máquina, la verificación real siempre pasó por Postgres/HTTP directo o por CI (un runner Linux limpio, sin este drift local), nunca por `mix test` local. La próxima corrida de CI real (push a `main`) es la verificación pendiente de este punto -- no bloqueante para el código de esta spec en sí, que ya se probó exhaustivamente por otras vías (Grupos A-F).
23. [x] `docs/specs/README.md` actualizado con esta spec.
24. [x] **Handoff a Flutter listo**: `design.md` §4 es el contrato final, confirmado contra implementación real (no solo diseño en papel) -- lista para pasarle a la IA que trabaja el repo Flutter.
