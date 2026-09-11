# SPEC-SYS-1109202605 — BC Motor: Tab Permisos y Alcance de Datos

**Documento:** Requirements · **Fase:** ✅ aprobada (2026-09-11) — documentación retroactiva, sin cambios de código.

**Alcance de esta spec**: documentar (retroactivo, ya implementado)
el tab **"Permisos"** de `BcMotorLive` — quinta spec del módulo BC
Motor. Cubre TRES mecanismos distintos que conviven en este mismo
tab: (1) la matriz de permisos CRUD + transiciones por rol
(`CatalogoPermisosLive`, embebida vía `live_render/3`), (2) Alcance de
Datos — qué FILAS puede ver/operar cada rol, y (3) Permisos de
detalle por estado — qué puede hacer cada estado del maestro con los
renglones de cada catálogo detalle (insertar/actualizar/borrar).

**Nota de alcance**: `CatalogoPermisosLive` también existe como
pantalla propia ("Permission Sets", con su propio buscador de
catálogo, fuera de BC Motor) — esta spec documenta su comportamiento
tal como se usa EMBEBIDA acá; el picker de catálogo standalone
(`@embebido? == false`) se menciona pero no se especifica en
detalle.

## 1. Visibilidad del tab

R1. EL SISTEMA DEBE mostrar el tab "Permisos" únicamente para
catálogos que NO son detalle — un catálogo detalle nunca tiene
permisos propios (los de su fila los da su maestro), mismo criterio
que ya regía el viejo link "Permisos" de `BcListLive` antes de que
existiera como tab.

## 2. Matriz de permisos por rol

R2. EL SISTEMA DEBE mostrar, para el catálogo actual, una fila por
cada rol de la empresa activa con un botón por cada acción CRUD
aplicable y un botón por cada transición configurada del catálogo
(etiqueta real de la transición, no el nombre técnico de la acción)
— cada botón resaltado si ese rol ya tiene ese permiso concedido.

R2a. LAS acciones CRUD ofrecidas DEPENDEN del tipo real de catálogo
— nunca las 4 fijas para cualquier caso: una Consulta (reporte de
solo lectura) ofrece únicamente "Leer" (ni el código de "crear"/
"editar"/"eliminar" existe para ese tipo); un catálogo detalle nunca
ofrece "Eliminar" (un renglón nunca se borra directo, solo por
transición — conceder ese permiso ahí no habilitaría nada real).

R3. CUANDO se hace clic en el botón de una acción para un rol, EL
SISTEMA DEBE conceder el permiso si no lo tenía, o revocarlo si ya lo
tenía — toggle inmediato, sin paso de confirmación ni modo borrador.

R4. EL rol **"administrador"** DEBE aparecer siempre con todos sus
botones deshabilitados y marcados como concedidos ("ve todo") — no
es una fila editable, es informativa: ese rol es comodín por diseño
(`Permissions.can?/3`), conceder/revocar ahí no tendría efecto real.

R5. EL SISTEMA DEBE ofrecer, por fila de rol (salvo "administrador"),
los atajos "Todos" (concede de una todas las acciones que ese rol
todavía no tiene) y "Ninguno" (revoca todas las que sí tiene) — cada
uno solo toca las acciones que están en el estado contrario al
deseado, no reintenta conceder lo ya concedido ni revocar lo ya
revocado.

## 3. Filtro de la matriz

R6. EL SISTEMA DEBE ofrecer dos modos de la matriz: "Todos los
roles" (default) o acotada a los roles de UN usuario puntual
(buscador por email) — cambiar de modo recarga la matriz completa
para ese filtro.

R7. CUANDO el usuario logueado es `super_admin`, EL SISTEMA DEBE
ofrecer un checkbox "Mostrar roles de Sysadmin" (oculto para
cualquier otro usuario) — controla si los roles de sistema/plataforma
aparecen mezclados con los roles de negocio de la empresa.

## 4. Alcance de Datos — activación

R8. CUANDO el catálogo es una Consulta (reporte, no un catálogo con
tabla física propia), EL SISTEMA DEBE mostrar Alcance de Datos como
informativo de solo lectura, heredado de su catálogo base — sin
ningún control propio, con el texto explícito de que para cambiarlo
hay que ir a Permisos del catálogo base.

R9. CUANDO el catálogo NO es una Consulta, EL SISTEMA DEBE ofrecer un
botón "+ Alcance de datos" / "✓ Alcance de datos — Quitar" que
activa/desactiva `alcance_habilitado` para todo el catálogo — sin
esto activado, el catálogo se comporta exactamente como siempre, sin
ningún filtro nuevo por fila.

R10. CUANDO se desactiva Alcance de Datos (R9), EL SISTEMA NO DEBE
borrar ninguna configuración existente (ni columnas físicas, ni las
filas de alcance por rol ya definidas) — apaga solo el flag, así que
reactivarlo más tarde recupera la configuración anterior tal como
estaba, sin pérdida.

## 5. Alcance de Datos por rol

R11. CUANDO Alcance de Datos está activo (R9) y el catálogo NO es una
Consulta, EL SISTEMA DEBE mostrar una sección aparte "Alcance de
datos por rol" — un concepto distinto de la matriz de acciones de la
§2 (QUÉ FILAS puede ver/operar, no QUÉ ACCIONES puede hacer) — con un
selector por rol entre los niveles, de más restrictivo a más amplio:
Solo lo propio, Su ubicación de inventario, Su unidad de ventas, Su
sucursal, Toda la empresa, Todas las empresas.

R12. ESTA sección (R11) DEBE listar únicamente los roles que ya
tienen algún permiso/transición concedida en este catálogo (§2) — un
rol sin ningún acceso todavía no tiene nada que acotar, se omite para
no saturar la lista.

R13. EL rol "administrador" DEBE aparecer con su selector
deshabilitado — siempre ve todo, sin importar cualquier alcance
configurado.

R14. UN rol sin ningún alcance configurado todavía DEBE
comportarse como "Solo lo propio" (el más restrictivo) por default
— nunca "Toda la empresa" ni ningún nivel más amplio por omisión.

## 6. Permisos de detalle por estado

R15. CUANDO el catálogo es maestro de uno o más catálogos detalle, EL
SISTEMA DEBE mostrar una tabla "Permisos de detalle": una fila por
cada ESTADO del maestro (no por rol) × tres columnas
(Insertar/Actualizar/Borrar) por cada catálogo detalle — controla si,
estando el maestro en ese estado puntual, se pueden insertar/editar/
borrar renglones de ese catálogo detalle.

R16. CUANDO el catálogo todavía no tiene ningún estado definido, EL
SISTEMA DEBE mostrar "Definí estados primero" en vez de una tabla
vacía o sin sentido (la tabla no tiene filas posibles sin estados).

R17. CADA celda de la tabla (R15) DEBE ser un toggle independiente
(concedido/no concedido) — clic alterna ese permiso puntual
(estado × catálogo detalle × acción), sin afectar ninguna otra celda.

## 7. Fuera de alcance de esta spec

- El uso standalone de `CatalogoPermisosLive` como pantalla
  "Permission Sets" (picker de catálogo propio, fuera de BC Motor).
- El modelo de datos completo de RBAC (`Permissions`, roles, cómo se
  resuelve `can?/3`) — documentado, si hace falta, en una spec propia
  de RBAC.
- El modelo de Alcance de Datos en profundidad (cómo se aplican los
  filtros en lectura/escritura contra la base) — acá solo se
  documenta la UI de configuración, no el motor que lo aplica.
