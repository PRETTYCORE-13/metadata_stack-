# SPEC-SYS-1709202601 — Sysadmin / Administrador de usuarios

**Documento:** Requirements · **Fase:** ✅ aprobada (2026-09-17, documentación retroactiva), con dos incrementos reales completos después (2026-09-17: eliminación total de un usuario, R13a-e; rediseño de la pestaña Roles a picker de doble lista, R14-R16 reemplazados — ambos implementados, testeados y verificados, ver `tasks.md`).

**Alcance de esta spec**: documentar (retroactivo, ya implementado, sin
tocar código) la pantalla `/sysadmin/usuarios`
(`MetadataAppWeb.Sysadmin.UsuariosEmpresaLive`) — el administrador de
usuarios de una empresa: alta, asignación de roles, capacidades de
Sysadmin, catálogos de solo lectura por herencia, y Alcance de Datos
(Empresa/Sucursal/Almacén/Unidad de venta), todo por usuario. Mismo
patrón que `SPEC-SYS-0909202601-framework-navegacion`: ancla para
futuros cambios reales sobre esta pantalla, no una foto que se vuelve a
escribir desde cero.

Acceso: requiere permiso `"leer"` sobre el recurso `sysadmin_usuarios`
(deny-by-default, mismo mecanismo que cualquier página del árbol de
navegación — ver `SPEC-SYS-0909202601` §2) o ser `administrador` de la
empresa (bypass total). El switch de esa capacidad puntual vive en la
pestaña "Sysadmin" de esta misma pantalla (§5).

## 1. Lista de usuarios (columna izquierda)

R1. EL SISTEMA DEBE mostrar, en la columna izquierda, la lista de
usuarios que pertenecen a la empresa gestionada (`empresa_en_foco`),
buscable por email en tiempo real (debounce 200ms).

R2. CUANDO un usuario en la lista todavía no confirmó su cuenta, EL
SISTEMA DEBE marcarlo visualmente ("Sin confirmar").

R3. EL SISTEMA DEBE ofrecer, dentro de la misma columna, un alta
directa por email: el administrador escribe cualquier email, el
sistema agrega esa cuenta a la empresa gestionada (si el email ya
existe como usuario, simplemente se suma a la empresa; si no existe,
la crea) y envía un correo con instrucciones de acceso (magic-link) —
reemplaza el autorregistro público, cerrado (ver `feedback` de
memoria del proyecto).

R4. EL SISTEMA DEBE validar el formato del email antes de intentar el
alta (sin round-trip a la base si el formato es inválido) y mostrar el
error de formato debajo del campo.

## 2. Usuarios sin empresa (cola de acceso pendiente)

R5. EL SISTEMA DEBE mostrar, en una sección aparte de la misma
columna, los usuarios que ya se autorregistraron (self-service,
magic-link) pero todavía no pertenecen a ninguna empresa.

R6. CUANDO un administrador agrega un usuario sin empresa a la empresa
gestionada, EL SISTEMA DEBE sumarlo y quitarlo de esa cola.

R7. CUANDO un administrador rechaza un usuario sin empresa, EL SISTEMA
DEBE eliminar la cuenta por completo (sin soft-delete — por
definición, ese usuario todavía no tiene ninguna empresa ni rol
asociado que perder) y pedir confirmación antes de hacerlo.

## 3. Selección y detalle del usuario

R8. CUANDO un administrador selecciona un usuario de la lista, EL
SISTEMA DEBE mostrar a la derecha su detalle en 5 pestañas: Generales,
Roles, Sysadmin, BC y Alcance.

R9. EL SISTEMA DEBE ofrecer un botón para cerrar el detalle
(deselecciona al usuario, vuelve al estado vacío).

## 4. Pestaña "Generales"

R10. EL SISTEMA DEBE mostrar el email del usuario (solo lectura) y si
la cuenta está confirmada o no.

R11. EL SISTEMA DEBE permitir editar el alias del usuario seleccionado,
con validación en vivo.

R12. EL SISTEMA DEBE ofrecer un botón para cerrar TODAS las sesiones
activas del usuario en cualquier dispositivo de forma inmediata (sin
esperar a que expiren los tokens por tiempo) — revoca los tokens en
base Y desconecta cualquier socket ya abierto, pide confirmación antes
de ejecutar.

R13. "Desactivar/bloquear cuenta" queda **fuera de esta entrega**
(pendiente, marcado en pantalla como "próximamente" — ver `project` de
memoria del proyecto).

### Eliminación total del usuario (2026-09-17, a pedido explícito)

Caso real que motivó este requisito: un administrador tipeó mal un
alta y quiere borrar esa cuenta por completo, no solo quitarla de una
empresa puntual.

R13a. EL SISTEMA DEBE ofrecer, en la pestaña "Generales" del usuario
seleccionado, una acción "Eliminar usuario" que borra esa cuenta POR
COMPLETO del ambiente — sin importar a cuántas empresas pertenezca ni
qué roles/alcance tenga en cada una (a diferencia de "Quitar" en la
pestaña Alcance §8, que solo desvincula de UNA empresa). No es un
soft-delete: la cuenta deja de poder autenticarse y desaparece de
cualquier listado.

R13b. EL SISTEMA DEBE pedir confirmación explícita antes de eliminar
un usuario — mismo patrón que "Cerrar todas las sesiones" (R12) y
"Rechazar" en la cola sin empresa (R7): un diálogo de confirmación que
deje claro que la acción no se puede deshacer.

R13c. EL SISTEMA NO DEBE ofrecer "Eliminar usuario" cuando el usuario
seleccionado es el mismo que está autenticado — un administrador no
puede eliminarse a sí mismo desde esta pantalla (evita quedar sin
acceso por error, sin nadie que lo revierta).

R13d. EL SISTEMA NO DEBE ofrecer "Eliminar usuario" cuando el usuario
seleccionado es sysadmin de plataforma (`super_admin`) — protege contra
quedarse sin ningún sysadmin de plataforma. Un usuario que es
`administrador` de una empresa común (sin ser sysadmin de plataforma)
SÍ se puede eliminar, sin ninguna guarda adicional más allá de la
confirmación de R13b.

R13e. CUANDO se elimina un usuario, EL SISTEMA DEBE quitarlo de
inmediato de la lista de la izquierda y cerrar su panel de detalle.

## 5. Pestaña "Roles" — picker de doble lista (rediseño 2026-09-17, a pedido explícito con mockup)

Reemplaza el buscador acotado (R15 original) por un picker de doble
lista ("transfer list"): izquierda = todos los roles disponibles de la
empresa gestionada que el usuario TODAVÍA NO tiene; derecha = los que
ya tiene. Motivo: gestión más directa para el volumen real de roles por
empresa (el roadmap de extensión RBAC habla de ~100 roles por empresa
— lejos de la escala de ~1000 catálogos que sí justifica
buscar-en-vez-de-listar).

R14. EL SISTEMA DEBE mostrar, en la lista IZQUIERDA, todos los roles
disponibles de la empresa gestionada (propios de esa empresa + de
sistema) que el usuario seleccionado TODAVÍA NO tiene — nunca roles de
OTRA empresa (misma frontera de aislamiento multi-tenant que ya regía
en el buscador anterior).

R15. EL SISTEMA DEBE mostrar, en la lista DERECHA, los roles YA
concedidos al usuario en la empresa gestionada, marcando si cada uno
es de sistema.

R16. EL SISTEMA DEBE permitir seleccionar UN rol a la vez (click,
selección simple) en cualquiera de las 2 listas.

R16a. CUANDO hay un rol seleccionado en la lista izquierda y el
administrador hace clic en la flecha "→", EL SISTEMA DEBE concederle
ese rol al usuario de inmediato (mismo mecanismo de
`Permissions.asignar_rol/3` que el resto del RBAC) — el rol pasa a la
lista derecha, la selección se limpia.

R16b. CUANDO hay un rol seleccionado en la lista derecha y el
administrador hace clic en la flecha "←", EL SISTEMA DEBE revocarle
ese rol al usuario de inmediato (soft-delete, mismo mecanismo de
`Permissions.revocar_rol/3` que el resto del RBAC) — el rol pasa a la
lista izquierda, la selección se limpia.

R16c. EL SISTEMA DEBE ofrecer un filtro de texto propio arriba de CADA
lista (izquierda y derecha, independientes entre sí) — filtra en el
cliente sobre la lista ya cargada, sin ida y vuelta al servidor
(ambas listas de una empresa son chicas, decenas no miles — no hace
falta el patrón buscar+limitar que sí usan los catálogos a escala de
~1000).

**Ajustes UX (2026-09-17, mismo día, a pedido explícito):**

R16d. EL SISTEMA DEBE dejar que cada lista (disponibles/asignados)
aproveche el espacio vertical disponible del panel — no una altura
fija chica con scroll interno.

R16e. EL SISTEMA DEBE ofrecer, junto a la lista de asignados, una
acción para quitarle al usuario TODOS los roles concedidos de una sola
vez, con confirmación explícita (mismo criterio que el resto de las
acciones destructivas de esta pantalla).

R16f. CUANDO se asigna un rol con la flecha "→", EL SISTEMA DEBE dejar
automáticamente seleccionado el primer rol de la lista de disponibles
que queda después de mover — así clicks repetidos de "→" asignan roles
consecutivos sin tener que volver a elegir cada uno a mano.

## 6. Pestaña "Sysadmin" (capacidades administrativas puntuales)

R17. EL SISTEMA DEBE mostrar un switch por cada capacidad de Sysadmin
existente (`Permissions.capacidades_sysadmin/0` — una pantalla del
menú "Sysadmin" por capacidad: Roles, Empresas, RBAC Usuarios, etc.),
permitiendo prender/apagar el acceso del usuario a esa pantalla
puntual sin concederle "administrador" completo.

R18. CADA switch DEBE concede/revocar únicamente el rol de sistema
dedicado de esa capacidad — mismo mecanismo (misma tabla, mismas
funciones `asignar_rol`/`revocar_rol`) que la pestaña "Roles"; no
existe un camino paralelo de permisos.

R19. CUANDO el rol de sistema de una capacidad todavía no fue sembrado
(migración de seed pendiente), EL SISTEMA DEBE mostrar ese switch
deshabilitado, con una indicación de por qué, en vez de fallar al
hacer clic.

## 7. Pestaña "BC" (catálogos, solo lectura)

R20. EL SISTEMA DEBE listar los catálogos que el usuario puede LEER en
la empresa gestionada, por herencia de sus roles — el mismo cálculo
que ya usa el árbol de navegación para podar el menú (ver
`SPEC-SYS-0909202601` §2). Esta pestaña es exclusivamente informativa:
no se editan permisos de catálogo desde acá.

## 8. Pestaña "Alcance" (Alcance de Datos: Empresa → Sucursal → Almacén / Unidad de venta)

R21. EL SISTEMA DEBE mostrar el Alcance de Datos del usuario de forma
GLOBAL (todas sus empresas, no solo la empresa gestionada por esta
pantalla) y anidada: Empresa en la raíz, con sus Sucursales asignadas
adentro, y cada Sucursal con su propio Almacén y Unidad de venta
adentro — un almacén o unidad de venta pertenece a una sola sucursal,
nunca se listan sueltos.

R22. EL SISTEMA DEBE permitir asignar/quitar Empresas, Sucursales,
Almacenes y Unidades de venta mediante un `<select>` de lo disponible
(nunca repite lo ya asignado) + botón "Agregar", y un botón "Quitar"
por cada renglón ya asignado.

R23. EL SISTEMA NO DEBE ofrecer el selector de Almacén/Unidad de venta
de una Sucursal hasta que esa Sucursal ya esté asignada al usuario
(dependencia jerárquica: sin sucursal, no hay de qué Almacén/Unidad de
venta hablar).

R24. EL SISTEMA DEBE permitir marcar, como máximo, una Empresa, una
Sucursal (por empresa) y un Almacén y una Unidad de venta (por
sucursal) como "default" — el default existente de esa misma
dimensión se reemplaza sin acción aparte al marcar uno nuevo; marcar
el que ya es default lo desmarca.

R25. CUANDO una empresa tiene sucursales asignadas pero ninguna
marcada como default, EL SISTEMA DEBE mostrar una advertencia visible
("falta default") — Empresa, Sucursal y Almacén default son
obligatorios para que el usuario pueda crear registros en catálogos
con Alcance de Datos.

R26. CUANDO un administrador quita la empresa que está siendo
gestionada por esta pantalla (`empresa_en_foco`) del alcance de un
usuario, EL SISTEMA DEBE, además de quitarla, sacar a ese usuario de
la lista de la izquierda y cerrar su detalle (pierde cualquier rol que
tuviera ahí). Quitar cualquier OTRA empresa solo refresca la pestaña
Alcance, sin afectar la lista visible.

## 9. Gestión multi-empresa (solo sysadmin de plataforma)

R27. CUANDO el usuario autenticado es sysadmin de plataforma
(`super_admin`), EL SISTEMA DEBE ofrecer un selector para elegir QUÉ
empresa gestiona esta pantalla (`empresa_en_foco`), sin necesidad de
unirse/activar esa empresa en su propia sesión — un administrador
normal (no super_admin) siempre gestiona únicamente su empresa activa,
sin ver ese selector.

R28. CUANDO se cambia la empresa gestionada, EL SISTEMA DEBE recargar
la lista de usuarios y limpiar cualquier detalle de usuario
seleccionado.

## 10. Fuera de alcance de esta spec

- El mecanismo de permisos RBAC en sí (`Permissions.can?/3`,
  asignación de roles a catálogos, alcance por tipo) — esta pantalla
  solo lo *consume* (asignar/revocar roles y capacidades puntuales de
  un usuario), no lo define. Ver el diseño general del motor en
  `project_motor_bc_design` (memoria del proyecto) y
  `docs/roadmap-rbac-extension.md`.
- Las pantallas "Roles" (`RolesLive`/`RolDetalleLive`) y "Empresas"
  (`EmpresasLive`) — mismo RBAC, eje invertido (fijan un rol/empresa y
  listan usuarios) y son o serán sus propias specs.
- "Desactivar/bloquear cuenta" (R13) — entrega futura.
- El modelo de datos de Alcance (`Autenticacion.Scope`,
  `UsuarioBranch`/defaults, `alcance_tipo_efectivo/2`) — esta pantalla
  solo es una UI de administración sobre ese modelo ya existente.
