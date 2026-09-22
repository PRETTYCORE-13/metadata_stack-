# SPEC-API-0409202601 — Autenticación móvil (Flutter) contra usuarios de metadata_stack

**Documento:** Design · **Fase:** ✅ aprobada (2026-09-04) — ver `tasks.md` para la siguiente fase.

## 1. Arquitectura

### 1.1 Dos tokens, mismo mecanismo de fondo: revocación instantánea (decisión, revisada 2026-09-04)

- **Refresh token** — opaco, guardado en DB **hasheado** (mismo patrón que ya usa `UsuarioToken` para magic-link/cambio de email: se manda crudo al cliente, se guarda `sha256` del valor). Necesita ser: revocable de inmediato (R7), listable con metadata (R7: cuándo se creó, último uso), y vivir 60 días (R1).
- **Access token** — `Phoenix.Token` firmado (HMAC con el `secret_key_base`, **sin dependencia nueva** — Phoenix lo trae de fábrica), vida corta (2hs, R1), payload `%{usuario_id: id, sesion_movil_id: id}`. La firma solo prueba que el token no fue alterado y cuándo se emitió — **no alcanza sola**: cada verificación además confirma con una consulta a la base que `sesion_movil_id` sigue existiendo (no fue revocada). Si la fila de `SesionMovil` ya no está, el access token se rechaza aunque su firma/expiración todavía sean válidas.

**Por qué una consulta a la base en cada request no es un costo nuevo**: el `/api` existente (sesión web por cookie) **ya hace exactamente esto** — `fetch_current_scope_for_usuario` verifica el token de sesión contra `meta_schema_usuario_tokens` en cada request (`UsuarioToken.verify_session_token_query/1`). Este mecanismo queda igual de consistente, solo contra la tabla nueva (`SesionMovil`) en vez de `UsuarioToken`. Se revirtió la idea original de un access token 100% stateless (sin consulta) porque este es un ERP con datos sensibles — la ventana de hasta 2hs de uso residual tras revocar no se consideró aceptable frente a un costo de performance que, en los hechos, ya se paga hoy para la sesión web.

**Optimización simple para no duplicar el lookup dentro de la misma request**: `ApiMovilAuth` (1.3) hace UN SOLO `Repo.get_by(SesionMovil, id: sesion_movil_id)` por request — el resultado (con `usuario_id`) es lo que arma `current_scope`, no hace falta una segunda consulta separada para "verificar" y otra para "cargar el usuario".

### 1.2 Nuevo pipeline, no se toca el existente

El `/api` actual (`router.ex:30`) autentica por **cookie de sesión** (`fetch_session` + `fetch_current_scope_for_usuario`) — sirve para llamadas del propio frontend web, no para un cliente mobile sin cookie. Se agrega un scope **separado** `/api/movil`, con su propio pipeline:

```elixir
pipeline :api_movil do
  plug :accepts, ["json"]
end

pipeline :api_movil_auth do
  plug :accepts, ["json"]
  plug MetadataAppWeb.ApiMovilAuth  # nuevo plug -- ver 1.3
end
```

`login`/`refrescar`/`logout` van bajo `:api_movil` (no requieren estar ya autenticado). Cualquier endpoint de negocio futuro que Flutter consuma va bajo `:api_movil_auth`.

### 1.3 `MetadataAppWeb.ApiMovilAuth` (plug nuevo)

Lee `Authorization: Bearer <access_token>`, verifica con `Phoenix.Token.verify(MetadataAppWeb.Endpoint, "movil access", token, max_age: 7200)`. Si la firma/expiración son válidas, busca `SesionMovil` por `sesion_movil_id` (§1.1) — si no existe (revocada), 401 igual que si el token fuera inválido. Si existe, arma `conn.assigns.current_scope` igual que hoy arma `Scope.for_usuario/1` (mismo struct que ya usa el resto del sistema — así cualquier endpoint futuro que ya sepa trabajar con `current_scope` funciona sin cambios). Si no es válido en cualquiera de los dos pasos: 401 `{"error": "no_autenticado"}`.

`ultimo_uso_en` (§2) se sigue actualizando solo en `/token/refrescar`, no acá — esta lectura ya es un `Repo.get_by` (necesario para la revocación instantánea, §1.1); convertirla también en un `UPDATE` en cada request de negocio sería una escritura por llamada solo para una fecha que R7 no necesita con precisión de segundos.

## 2. Modelo de datos

Tabla nueva `meta_schema_usuario_sesion_movil` — deliberadamente **aparte** de `meta_schema_usuario_tokens` (aunque la NFR de requirements.md permitía reusarla): esta necesita campos que esa tabla no tiene (`ultimo_uso_en`, etiqueta de dispositivo para R7) y un ciclo de vida distinto (se actualiza en cada refresh, los tokens existentes son de un solo uso/fire-and-expire).

```elixir
defmodule MetadataApp.Autenticacion.SesionMovil do
  use Ecto.Schema

  schema "meta_schema_usuario_sesion_movil" do
    field :refresh_token_hash, :binary
    field :etiqueta_dispositivo, :string  # opcional -- lo manda el cliente (ej. "iPhone de Juan"), solo para mostrar en R7
    field :ultimo_uso_en, :utc_datetime
    belongs_to :usuario, MetadataApp.Autenticacion.Usuario

    timestamps(type: :utc_datetime, updated_at: false)
  end
end
```

- **Generación del refresh token**: mismo patrón que `UsuarioToken.build_hashed_token/3` — `:crypto.strong_rand_bytes(32)` crudo al cliente (`Base.url_encode64`), `:crypto.hash(:sha256, ...)` guardado en `refresh_token_hash`.
- **Validación de vigencia (R1/R4, los 60 días)**: `inserted_at` de la fila ES la fecha de emisión — no hace falta un campo `expira_en` aparte. `/token/refrescar` busca la fila por `refresh_token_hash` con `where: sesion.inserted_at > ago(60, "day")`, mismo patrón exacto que ya usa `UsuarioToken.verify_session_token_query/1` para las 12hs de la sesión web (solo que acá la ventana es 60 días, no 12hs). Si la fila existe pero ya pasó ese umbral, cuenta como "no encontrada" a los efectos de R4 (401 `refresh_token_invalido`) — no se borra activamente al vencer (no hace falta un job de limpieza para que la lógica sea correcta), aunque puede valer un `mix` task de housekeeping para no acumular filas viejas indefinidamente (a definir en `tasks.md`, no cambia el contrato).
- **Revocar (R7/R8)** = `Repo.delete` de la fila — no hace falta un campo `revocado_en`, ausencia de fila ya es "no existe más" (mismo criterio que el logout web borra su `UsuarioToken` de contexto `"session"`).
- **`ultimo_uso_en`** se actualiza en cada llamada exitosa a `/api/movil/token/refrescar` (no en cada request con access token — eso sería una escritura por request, contra el punto de que el access token no toque la base).
- Migración agrega la tabla + índice en `refresh_token_hash` (lookup) y `usuario_id` (listado de R7).

## 3. Rate limiting (R10)

Contador en memoria vía `:ets`, sin dependencia nueva — no necesita persistir entre reinicios del nodo (una ventana de minutos, perder el contador en un deploy no es un problema real). `MetadataApp.Autenticacion.LimiteIntentos`:

- Clave: `{:login, email_normalizado}` — por email, no por IP (una API pública detrás de balanceadores/NAT puede compartir IP entre usuarios legítimos; el objetivo es frenar fuerza bruta contra UNA cuenta).
- 5 intentos fallidos en 15 minutos → bloquea intentos nuevos para ese email hasta que la ventana expire (respuesta `429 {"error": "demasiados_intentos", "reintentar_en_segundos": N}`).
- Un login exitoso limpia el contador de ese email.
- **Mismo contador/clave para `/verificar` (R11)**: un intento de `/verificar` que devuelve `existe: false` cuenta como "fallido" para el límite — si no, `/verificar` sería una forma de probar emails al infinito sin límite, sorteando la protección que sí tiene `/login`.

## 4. Contrato de API (para la app Flutter)

Base: `https://<host>/api/movil`. Todo el body es JSON (`Content-Type: application/json`), toda respuesta es JSON.

### `POST /verificar` (R11 -- paso previo, antes de pedir contraseña)

No hace falta mandar la URL de la instancia en el body -- **el request ya se manda directo a esa URL** (`https://<host-del-cliente>/api/movil/verificar`), así que "verificar que la instancia existe" es simplemente "el request llegó y devolvió esta forma de JSON" (si la URL está mal, Flutter ve un error de conexión/timeout/404 genérico de HTTP, no hace falta que este endpoint le agregue nada a eso).

Request: `{ "email": "usuario@ejemplo.com" }`

200 (el email pertenece a un usuario de esta instancia):
```json
{ "existe": true, "empresa": { "nombre": "Empresa Default S.A." } }
```
404 (no pertenece): `{"existe": false, "error": "usuario_no_encontrado"}`
429 (R10, mismo límite que `/login` aplicado también acá -- ver NFR "tradeoff aceptado en R11" de requirements.md): `{"error": "demasiados_intentos", "reintentar_en_segundos": N}`

No crea ninguna sesión ni token -- es de solo lectura (resuelve `empresa_default_id` igual que R9, pero sin loguear a nadie).

### `POST /login`
Request:
```json
{ "email": "usuario@ejemplo.com", "password": "...", "etiqueta_dispositivo": "iPhone de Juan" }
```
`etiqueta_dispositivo` opcional (default: `null`, se muestra como "Sesión sin nombre" en R7).

200:
```json
{
  "access_token": "...",
  "refresh_token": "...",
  "access_token_expira_en": 7200,
  "usuario": { "id": 1, "email": "usuario@ejemplo.com", "alias": "Juan" },
  "empresa": { "id": 3, "nombre": "Empresa Default S.A." }
}
```
401 (credenciales inválidas): `{"error": "credenciales_invalidas"}`
429 (R10): `{"error": "demasiados_intentos", "reintentar_en_segundos": 612}`

### `POST /token/refrescar`
Request: `{ "refresh_token": "..." }`
200: `{ "access_token": "...", "access_token_expira_en": 7200 }`
401 (vencido/revocado/inexistente): `{"error": "refresh_token_invalido"}` — la app debe volver a `/login`.

### `DELETE /sesion`
Request: `{ "refresh_token": "..." }` — poseer el refresh token alcanza para revocarlo, no requiere `Authorization` aparte.
204 sin body (idempotente: si ya no existía, también 204).

### Endpoints de negocio futuros
`Authorization: Bearer <access_token>` en el header. 401 `{"error": "no_autenticado"}` si falta/es inválido — mismo shape de error que los de arriba.

## 5. Panel web (R7)

Nueva pantalla en Sysadmin (o dentro del perfil del propio usuario — **a confirmar en tasks.md**, no es una decisión de contrato de API) que lista `SesionMovil` del usuario: `etiqueta_dispositivo` (o "Sesión sin nombre"), `inserted_at` ("creada"), `ultimo_uso_en` ("última vez usada"), botón "Cerrar sesión" por fila → `Repo.delete` de esa fila.

## 6. Preguntas abiertas

Ninguna pendiente. La única (dónde vive la pantalla de R7) se resolvió:
**Sysadmin** (no existe hoy ninguna pantalla de "mi perfil"/configuración
de cuenta en el proyecto — armar una desde cero solo para esto sería
alcance extra no pedido; Sysadmin ya tiene el patrón de permisos/nav
listo para reusar, mismo criterio que Credenciales/Ambientes/Panel
Control).
