# SPEC-API-0409202601 — Autenticación móvil (Flutter) contra usuarios de metadata_stack

**Documento:** Requirements · **Fase:** ✅ aprobada (2026-09-04) — ver `design.md` para la siguiente fase.

## 1. Propósito

La app Flutter necesita una pantalla de login nativa propia, pero sin
tener su propio catálogo de usuarios: el usuario/contraseña que valida
es el mismo `Usuario` que ya existe en metadata_stack (misma tabla,
mismo hash de contraseña). metadata_stack no tiene hoy ningún mecanismo
de autenticación por token — solo sesión web por cookie, deliberadamente
sin persistencia larga ("recordarme" fue descartado a propósito el
2026-08-06 por ser un ERP con datos sensibles). Este spec agrega un
mecanismo de token **aparte**, pensado para el modelo de riesgo de un
dispositivo móvil (revocable por dispositivo) — no reabre ni cambia esa
decisión de la sesión web.

La app Flutter es **genérica**: no está atada a un único servidor. Cada
cliente tiene su propia instancia de metadata_stack desplegada por
separado (vía Panel Control, ver `MetadataApp.PanelControl.Desplegador`)
en su propia URL — y dentro de esa instancia, un usuario pertenece a una
o más Empresas (multi-tenancy ya existente, `UsuarioEmpresa`). Antes de
poder loguear a nadie, la app necesita saber CONTRA CUÁL servidor está
hablando (agregado 2026-09-04, a pedido explícito — ver R11).

**Actores:**
- **Usuario final** — ingresa la URL de su instancia y su email antes que nada; una vez confirmado que existe ahí, se loguea con email+contraseña; permanece logueado entre aperturas de la app sin volver a escribir la contraseña cada vez.
- **Administrador/el propio usuario** — desde el panel web, puede ver qué sesiones móviles están activas y cerrar cualquiera puntualmente (ej. teléfono perdido/robado).
- **Sistema** — emite, valida y revoca los tokens; nunca acepta uno vencido o revocado.

## 2. Alcance

**Incluye:**
- Endpoint de API para verificar, antes del login, que la URL ingresada es una instancia real y que el email pertenece a un `Usuario` de esa instancia — devuelve a qué Empresa pertenece para mostrarlo en pantalla antes de pedir la contraseña.
- Endpoint de API para login con email+contraseña, reusando la verificación de contraseña ya existente (`Usuario.valid_password?/2`, Pbkdf2).
- Emisión de un **access token** (vida corta) + **refresh token** (vida larga, revocable) por cada login.
- Endpoint para renovar el access token a partir de un refresh token válido, sin pedir contraseña de nuevo.
- Cada login desde Flutter es una "sesión"/dispositivo identificable por separado — un usuario puede tener varias activas a la vez (varios teléfonos, o teléfono + tablet).
- Vista en el panel web de sesiones móviles activas del usuario, con acción de revocar cualquiera individualmente.
- Endpoint de logout explícito (revoca la sesión actual desde la propia app).
- Login entra directo con la `empresa_default_id` del usuario (igual que hoy la web) — sin selector de empresa.

**No incluye (explícitamente fuera de esta v1):**
- Cualquier pantalla, código o lógica del lado Flutter/Dart — este spec y su `design.md` son el contrato que se le entrega a la IA que trabaja ese repo, no se toca ese código desde acá.
- Selector de empresa en el login (usuarios multi-empresa) — usa la default, igual que hoy la web.
- Alta/registro de usuarios nuevos desde la app — los usuarios se siguen dando de alta solo desde el panel web/flujo existente.
- Magic-link desde mobile — solo email+contraseña (confirmado explícitamente).
- Recuperación de contraseña con flujo propio de la app — si un usuario mobile la olvida, usa el flujo web existente desde un navegador (confirmado).
- Cambiar la sesión web existente (cookie, sin `max_age`, 12h) — sigue exactamente igual, este mecanismo es aparte.

## 3. Glosario

| Término | Significado |
|---|---|
| Access token | Token de vida corta que la app manda en cada request autenticado a la API. Si está vencido, el request se rechaza sin importar nada más — hay que pedir uno nuevo con el refresh token. |
| Refresh token | Token de vida larga, guardado en el dispositivo, que **solo** sirve para pedir un access token nuevo — nunca se manda como credencial de un request de negocio. |
| Sesión móvil / dispositivo | Cada login desde Flutter genera un refresh token propio e independiente — revocar uno no afecta a los demás ni a la sesión web. |
| Revocar | Invalidar un refresh token de inmediato — cualquier intento posterior de usarlo para pedir un access token nuevo falla, sin importar que todavía no haya "expirado" por tiempo. |
| Empresa activa / `empresa_default_id` | Ya existen en el sistema (`Usuario`/`UsuarioEmpresa`) — la empresa con la que el login entra automáticamente. |
| Instancia | Un despliegue de metadata_stack completo y separado, en su propia URL, con su propia base de datos — cada cliente tiene la suya (ver Panel Control, `MetadataApp.PanelControl.Desplegador`). Un "usuario" solo existe dentro de UNA instancia; el mismo email en dos instancias distintas son dos `Usuario` sin relación. |

## 4. Requisitos funcionales

### R1. Login con credenciales válidas
CUANDO la app Flutter manda un email y contraseña que corresponden a un `Usuario` existente y la contraseña es correcta, EL SISTEMA DEBE emitir un access token (vigencia 2 horas) y un refresh token nuevos (vigencia 60 días), y devolver junto con ellos la empresa activa (`empresa_default_id`) del usuario. No se chequea `confirmed_at` — mismo comportamiento que el login web con contraseña hoy (`get_usuario_by_email_and_password/2` no lo valida).

### R2. Login con credenciales inválidas
CUANDO el email no existe o la contraseña no coincide, EL SISTEMA DEBE rechazar el login sin revelar cuál de las dos cosas falló (mismo criterio de `Pbkdf2.no_user_verify/0` que ya usa la web, para no filtrar qué emails existen).

### R3. Renovar el access token
CUANDO la app manda un refresh token válido y no revocado al endpoint de renovación, EL SISTEMA DEBE emitir un access token nuevo, sin requerir la contraseña de nuevo.

### R4. Refresh token inválido
CUANDO el refresh token mandado a renovación está vencido, revocado, o no existe, EL SISTEMA DEBE rechazar la renovación — la app debe volver a pedir email+contraseña.

### R5. Access token vencido
CUANDO cualquier endpoint protegido de la API recibe un access token vencido, EL SISTEMA DEBE rechazar el request sin importar qué tan reciente sea el vencimiento.

### R6. Multi-dispositivo
CUANDO un mismo usuario hace login desde Flutter más de una vez (mismo o distinto dispositivo), EL SISTEMA DEBE tratar cada login como una sesión independiente — cada una con su propio refresh token, revocable sin afectar a las demás.

### R7. Ver y revocar sesiones desde el panel web
CUANDO un usuario autorizado consulta sus sesiones móviles activas desde el panel web, EL SISTEMA DEBE mostrar la lista (con al menos: cuándo se creó, última vez usada) y permitir revocar cualquiera individualmente — la revocación es inmediata.

### R8. Logout explícito
CUANDO la app Flutter pide logout, EL SISTEMA DEBE revocar el refresh token de esa sesión de inmediato.

### R9. Empresa automática
CUANDO el login es exitoso, EL SISTEMA DEBE resolver la empresa activa usando `empresa_default_id` del usuario, igual que ya hace la web — sin pedirle al usuario que elija, incluso si pertenece a más de una empresa.

### R10. Límite de intentos fallidos (agregado 2026-09-04, a pedido explícito)
CUANDO se acumulan demasiados intentos fallidos de login para un mismo email o una misma IP en una ventana de tiempo corta, EL SISTEMA DEBE bloquear intentos adicionales temporalmente — a diferencia del login web (que hoy no tiene esta protección), este endpoint es una API JSON pública, más expuesta a ataques de fuerza bruta scripteados.

### R11. Verificar instancia + usuario antes del login (agregado 2026-09-04, a pedido explícito)
CUANDO la app Flutter manda una URL de instancia y un email, ANTES de pedir la contraseña, EL SISTEMA DEBE responder si esa instancia existe y responde, y si ese email corresponde a un `Usuario` real ahí — sin revelar más que eso (ni si el email existe cuando la instancia no responde, ni datos del usuario más allá de con qué Empresa se muestra en pantalla). Si el email no pertenece a ningún usuario de esa instancia, EL SISTEMA DEBE devolver un error claro y distinto del que da una contraseña incorrecta (R2) — para que la app pueda decir "no encontramos ese usuario acá" en vez de "contraseña incorrecta". Este paso no reemplaza R1/R2 (login real) — es un paso previo informativo, la validación real de la contraseña sigue pasando en `/login`.

## 5. Requisitos no funcionales

- **Revocación real, no solo expiración**: un refresh token revocado deja de servir de inmediato, no "en la próxima renovación" — necesario para que R7 (perder el teléfono) sea una protección real.
- **No reusar el mecanismo de sesión web**: el token de mobile es un mecanismo aparte de `UsuarioToken` contexto `"session"` (cookie) — puede reusar la MISMA tabla/patrón de tokens opacos que ya existe en el sistema (contextos `"session"`/`"login"`/`"change:*"`), agregando un contexto nuevo, pero no debe interferir con la sesión web existente.
- **Mismo estándar de seguridad de contraseña**: la verificación sigue siendo Pbkdf2 vía `Usuario.valid_password?/2` — no se agrega un segundo mecanismo de hash.
- **Auditable**: cada sesión móvil debe quedar identificable (para poder listarla en R7) — no puede ser un token anónimo sin registro.
- **Tradeoff aceptado en R11**: a diferencia de R2 (login real, que NO revela si un email existe), R11 sí confirma explícitamente si un email pertenece a un usuario de esa instancia — a propósito, para poder mostrar un error claro ("no encontramos ese usuario") en vez de uno genérico. Es una forma acotada de enumeración de emails, pero solo dentro de una instancia que el atacante ya necesita conocer de antes (no hay una lista pública de instancias) — riesgo considerado aceptable a cambio de mejor UX. R10 (límite de intentos) también aplica a R11, no solo a `/login`, para no dejarlo abierto a fuerza bruta de emails.

## 6. Preguntas abiertas

Ninguna pendiente — las 4 originales se resolvieron y ya están
incorporadas: duración de tokens (R1: 2hs access / 60 días refresh),
recuperación de contraseña vía flujo web existente (Alcance §2, no
incluye), límite de intentos fallidos (R10, también cubre R11), y
`confirmed_at` sin chequear, igual que la web (R1). La verificación de
instancia+usuario (R11) se agregó completa, sin preguntas pendientes
propias.
