# SPEC-SYS-0909202602 — Demo: Gestión de Perros

**Documento:** Design · **Fase:** 🔵 en revisión.

Todo esto se arma con el Motor BC real (BPB + motor de estados vía
Sysadmin), sin atajos de código a mano — `tasks.md` va a ser una lista
de pasos hechos desde la UI (BC Motor Live) más que código Elixir
nuevo.

## 1. El catálogo (Header)

| Propiedad | Valor |
|---|---|
| `schema_context_name` | `pty_perros` (mismo prefijo `pty_` que el resto de catálogos de negocio del sistema) |
| `schema_context_label` | Perros |
| `schema_context_type` | 1 (maestro normal — no carpeta, no consulta) |
| `schema_encabezado_id` | *(vacío)* — no es detalle de nada, y no tiene detalles propios (R§1/§5) |
| `schema_visible` | `true` — para que R9 (aparece en el menú) se cumpla |
| `schema_es_transaccional` | `false` — no necesita TRN/folio, nada en los requisitos lo pide |

## 2. Campos (Detail)

| Campo | Etiqueta | Tipo (vocabulario del BPB) | Requerido |
|---|---|---|---|
| `nombre` | Nombre | `string` | sí (R1) |
| `raza` | Raza | `string` | sí (R2) |
| `edad_promedio` | Edad promedio | `integer` | no (R3) |
| `observaciones_vacunas` | Observaciones de vacunas | `texto_largo` | no (R4) |
| `nombre_dueno` | Nombre del dueño | `string`, longitud máx. 200 | no (R5) |

## 3. Estados y transiciones (motor de estados)

Dos estados:

| Estado | `es_inicial` | Orden |
|---|---|---|
| Activo | `true` | 1 |
| Baja | `false` | 2 |

Tres transiciones:

| `accion` | Etiqueta | Origen → Destino | Requisito |
|---|---|---|---|
| `alta` | Dar de alta | *(ninguno)* → Activo | R6 |
| `dar_de_baja` | Dar de baja | Activo → Baja | R7 |
| `reactivar` | Reactivar | Baja → Activo | R8 |

Sin reglas PRE/POST — ningún requisito pide validación ni efecto
colateral más allá del cambio de estado en sí.

## 4. RBAC

R9 (aparece en el menú) depende del permiso `{"pty_perros", "leer"}`.
R10 (ejecutar cada transición) depende de un permiso por `accion`:
`{"pty_perros", "alta"}`, `{"pty_perros", "dar_de_baja"}`,
`{"pty_perros", "reactivar"}` — mismo modelo que cualquier catálogo con
motor de estados (nunca un "editar" genérico para transiciones, ver
`Permissions.estado_permisos_para_pares/2`). Se conceden al rol que se
use para probar (ej. el mismo `pty-dsd-admin` creado antes, o uno
nuevo) desde "RBAC Business Context" en Sysadmin — no hace falta
código, es la misma pantalla que ya se usó para conceder permisos de
`pty_dsd_*`.

## 5. Mecanismo — 100% Motor BC, sin código a mano

1. **BC Motor Live** (Sysadmin → Business Process Builder → "BC
   Nuevo"): define el Header (§1) + los 5 campos (§2). Esto corre
   `CatalogoGenerador` — arma la migración, crea la tabla física, y
   escribe `lib/metadata_app/meta_business_process/catalogos/pty_perros.ex`
   (autogenerado, nunca a mano).
2. **Mismo BC Motor Live, paso "Estados"**: define los 2 estados y las
   3 transiciones de §3 (`MetaEstadosAdmin.crear_proceso_completo/1`
   por debajo, disparado desde la UI).
3. **RBAC Business Context** (Sysadmin): concede los 4 permisos de §4
   al rol elegido.
4. **Verificación real** (no solo que compile): loguearse con un
   usuario que tenga ese rol, confirmar que "Perros" aparece en el
   menú, dar de alta un perro, darlo de baja, reactivarlo — igual que
   cualquier catálogo real, en developer local.

Sin publicar a ningún sistema (fuera de alcance, requirements.md §5) —
el ejercicio termina en el paso 4, verificado en developer.
