# SPEC-SYS-0909202601 — Framework de Navegación

**Documento:** Requirements · **Fase:** ✅ aprobada (2026-09-09), con un incremento real después (2026-09-09/10: menú administrativo reorganizado — ver `tasks.md`, Grupos A-F). Se actualiza acá primero cuando haya un cambio real que planear sobre el framework.

**Alcance de esta spec**: documentar (retroactivo, ya implementado, sin
tocar código) el "framework" — la estructura fija que envuelve toda
pantalla autenticada: banda lateral izquierda (sidebar), banda superior
(topbar), banda inferior (footer) y menú de usuario. Solo la
**navegación** — cómo se llega a cada pantalla y qué acciones globales
hay siempre disponibles. El CONTENIDO de cada opción del menú (BC List,
Roles, Jerarquía, etc.) es responsabilidad de sus propias specs, no de
esta.

## 1. Sidebar (banda lateral izquierda)

R1. CUANDO un usuario autenticado carga cualquier pantalla, EL SISTEMA
DEBE mostrar un árbol de navegación en forma de carpetas colapsables
(estilo explorador de archivos), con carpetas y páginas anidadas a
cualquier profundidad.

R2. CUANDO el árbol de navegación se arma, EL SISTEMA DEBE mostrar
únicamente las páginas sobre las que el usuario tiene permiso de
"leer" en la empresa activa — una carpeta sin ninguna página visible
adentro (recursivo) tampoco se muestra.

R3. CUANDO un usuario escribe texto en el buscador del sidebar, EL
SISTEMA DEBE filtrar el árbol a las coincidencias (también acepta
pegar una ruta directa).

R4. CUANDO un usuario hace clic en el botón de colapsar/expandir del
sidebar, EL SISTEMA DEBE alternar entre el riel angosto (solo íconos)
y el expandido (íconos + nombres), y recordar esa preferencia entre
sesiones.

R5. CUANDO un usuario abre una carpeta de nivel raíz con el riel
colapsado, EL SISTEMA DEBE mostrar un panel flotante ("flyout") pegado
al borde del riel con las opciones de esa carpeta, en vez de expandir
el riel completo — abrir una carpeta raíz distinta reemplaza el
flyout anterior (nunca dos abiertos a la vez), y el flyout es
mutuamente excluyente con el riel expandido.

R6. CUANDO la carpeta que contiene la página actualmente activa se
renderiza, EL SISTEMA DEBE mostrarla ya abierta, sin que el usuario
tenga que expandirla a mano.

R7. CUANDO un usuario arrastra el borde derecho del sidebar (o del
flyout), EL SISTEMA DEBE permitir ajustar su ancho, y recordar ese
ancho entre sesiones.

R8. CUANDO la pantalla es de tamaño móvil, EL SISTEMA DEBE ocultar el
sidebar por default, mostrarlo mediante un botón de menú hamburguesa
en la topbar, y cerrarlo automáticamente al navegar a cualquier
página o al tocar fuera de él (overlay).

R9. EL SISTEMA DEBE ofrecer, dentro del encabezado del sidebar, un
control para cambiar entre tema claro y oscuro — la elección persiste
entre sesiones.

## 2. Topbar (banda superior)

R10. EL SISTEMA DEBE mostrar siempre, en la topbar, el nombre de la
empresa activa de la sesión actual (nunca un valor fijo de
configuración si ya existe una sesión con empresa resuelta).

R11. EL SISTEMA DEBE mostrar un ícono de notificaciones (campana) con
indicador de novedades, siempre visible en la topbar.

R12. EL SISTEMA DEBE mostrar el usuario autenticado (avatar o inicial
del nombre + nombre) en la topbar — **corregido (2026-09-09)**: es
puramente informativo, no despliega ningún menú al hacer clic (ver §3,
el menú administrativo se accede solo desde el engrane del sidebar).

## 3. Menú administrativo (dropdown)

**Cambiado (2026-09-09, a pedido explícito)** — este menú deja de
vivir en la topbar y de tratar sus 11 opciones como un bloque único.
Ahora es un solo panel reorganizado en dos grupos, con un ÚNICO punto
de entrada: el ícono de engrane/configuración en la parte inferior del
sidebar (R22). **Corregido el mismo día**: la primera versión ofrecía
un segundo acceso desde el avatar de la topbar — se sacó a pedido
explícito ("quitalo de la imagen del usuario, solo se puede acceder al
menú desde el engrane"). El avatar de la topbar (R12) queda puramente
informativo, sin acción al hacer clic.

R13. EL SISTEMA DEBE mostrar, dentro del menú administrativo, las
opciones **Roles Admin**, **Empresas**, **RBAC Usuarios**, **RBAC
Business Context** y **Jerarquía organizacional** — cada una
condicionada ÚNICAMENTE al permiso de "leer" del usuario sobre su
recurso correspondiente (mismo criterio que cualquier catálogo, ver
`SPEC-SYS-0909202601` §1 R2), **en cualquier ambiente** (developer,
unstable, testing, stable, cliente final). Ya no dependen de que el
usuario sea "sysadmin".

R13a. CUANDO el usuario es **sysadmin de plataforma** (`usuario.
super_admin == true` — el mismo campo que ya decide si existe algún
sysadmin en el primer arranque, no un concepto nuevo), EL SISTEMA DEBE
mostrarle además, en el menú administrativo: **Credenciales**,
**Ambientes de Deploy**, **Panel de Control** y **Acciones externas**
— nunca a un usuario que no sea sysadmin de plataforma, sin importar
qué permisos RBAC de catálogo tenga.

R13b. CUANDO el usuario es sysadmin de plataforma Y está en un
ambiente de developer local (`bpb_habilitado`, ver
`docs/arquitectura-bpb.md`), EL SISTEMA DEBE mostrarle además
**"Business Process Builder"** y **"Tepache Exp/Imp"** (mismo gate
`bpb_habilitado` que ya usa hoy, sin cambios) — **confirmado
explícitamente (2026-09-09): nunca en unstable/testing/stable/cliente**,
el BPB sigue siendo exclusivo de developer, esta spec no cambia esa
regla.

R13c. Sin ninguna opción de R13/R13a/R13b concedida/aplicable, EL
SISTEMA DEBE ocultar el menú administrativo por completo (ambos
accesos) — nunca un menú vacío.

R14. CUANDO el usuario tiene una empresa activa en su sesión, EL
SISTEMA DEBE ofrecer en el menú administrativo la opción "Cambiar
Unidad Operativa", que abre un modal para reasignar Empresa/Sucursal/
Almacén/Unidad de Venta activos en un solo paso (no campo por campo).

R15. EL SISTEMA DEBE ofrecer siempre, en el menú administrativo,
"Configuración de cuenta" (abre un modal de perfil) y "Cerrar sesión"
(pide confirmación antes de cerrar la sesión).

R22. EL SISTEMA DEBE mostrar, en la parte inferior del sidebar, un
ícono de engrane/configuración que abre el menú administrativo — el
ÚNICO acceso a ese menú (corregido 2026-09-09; ver nota al inicio de
esta sección).

## 4. Footer (banda inferior)

R16. EL SISTEMA DEBE mostrar siempre, en el footer, el aviso de
copyright de la plataforma con el año actual.

R17. CUANDO el usuario tiene una sesión con empresa activa, EL SISTEMA
DEBE mostrar en el footer, de solo lectura, la jerarquía operativa
activa (Empresa / Sucursal / Almacén / Unidad de Venta) — cambiarla es
exclusivo del modal de R14, el footer nunca la edita directo.

R18. CUANDO la Unidad Operativa activa (Empresa+Sucursal+Almacén)
cambia respecto de lo que el navegador tenía guardado, EL SISTEMA DEBE
avisar al usuario del cambio.

R19. EL SISTEMA DEBE ofrecer, en el footer, un botón para copiar la
ruta de navegación de la pantalla actual.

R20. EL SISTEMA DEBE ofrecer, en el footer, un buscador directo por
TRN (identificador de transacción/documento) accesible desde
cualquier pantalla.

R21. CUANDO la pantalla es de tamaño móvil, EL SISTEMA DEBE ocultar el
footer por default (libera espacio de pantalla) y ofrecer un botón
para mostrarlo/ocultarlo a demanda.

## 5. Fuera de alcance de esta spec

- El contenido/comportamiento propio de cada pantalla del menú (BC
  List, Roles, Jerarquía organizacional, Buscador TRN, etc.) — cada
  una es o será su propia spec.
- El mecanismo de permisos RBAC en sí (`Permissions.can?/3`, alcance de
  datos) — este framework solo lo *consume* para podar el árbol y el
  menú de Sysadmin, no lo define.
- El detalle de theming/CSS (paleta, tokens) — solo se documenta que
  existe el control y que persiste, no cómo se implementa visualmente.
