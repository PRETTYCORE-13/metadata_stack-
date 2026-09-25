# SDD anchored — cómo trabajamos acá

Spec-Driven Development ("anchored"): la especificación es el documento
vivo que **ancla** cada sesión de trabajo con la IA — nunca se le pide
código directo sobre una idea suelta. El flujo es siempre:

```
00.doc_human.md → 01.requirements.md → 02.design.md → 03.tasks.md → 04.implementación → 05.usage.md
      ↑                                                                                   │
      └───────────────────────────── se vuelve a leer ────────────────────────────────────┘
```

Los archivos de cada spec llevan el prefijo numérico (`00.`, `01.`,
`02.`, `03.`, `05.`) para que el orden de fases sea también el orden
alfabético/visual en el directorio — sin tener que memorizar la
secuencia, se lee de arriba hacia abajo tal cual aparece listada.

## Las 5 fases (nunca se saltean, nunca se mezclan)

0. **`00.doc_human.md`** — QUÉ es la spec y PARA QUÉ sirve, en lenguaje
   100% llano. Tiene que ser entendible por cualquier persona sin
   conocimiento técnico: un desarrollador nuevo, alguien de ADN, un
   asesor de servicio a cliente. Sin EARS, sin nombrar tablas, módulos,
   ni código — es la puerta de entrada para capacitar gente, y también
   el resumen que evita tener que pedirle a la IA "explicame la spec".
   3-5 párrafos: qué problema resuelve, para quién, y cómo se ve el
   flujo de principio a fin contado como una historia. Es el documento
   más estable de los cuatro — al ser puramente conceptual, casi nunca
   cambia cuando iteran `02.design.md`/`03.tasks.md`; solo se actualiza
   si cambia el alcance o el propósito de la spec. Arranca directo con
   el contenido — sin meta-explicación de "qué es este documento" o
   "para quién es" (eso ya lo dice el nombre del archivo y esta sección
   del README).

1. **`01.requirements.md`** — QUÉ tiene que hacer el sistema, desde la
   perspectiva de quien lo usa. Sin mencionar tablas, módulos ni código.
   Notación EARS (fácil de leer, sin ambigüedad):
   > CUANDO `<evento/condición>` EL SISTEMA DEBE `<comportamiento>`

   Ejemplo real: "CUANDO un administrador da de baja un perfil de
   numeración, EL SISTEMA DEBE dejar de asignarlo en futuras
   solicitudes, sin borrar su historial de folios ya asignados."

2. **`02.design.md`** — CÓMO se resuelve lo de arriba. Acá sí entran
   decisiones técnicas: modelo de datos, módulos, algoritmos,
   diagramas. Se escribe DESPUÉS de que `01.requirements.md` está
   aprobado — nunca antes, nunca en paralelo ("spec pura": una fase
   cierra antes de abrir la siguiente).

3. **`03.tasks.md`** — la lista de pasos concretos e incrementales para
   construir el diseño, cada uno chico y verificable (compila, corre,
   un test pasa). Es el ÚNICO documento contra el que se pide código.

4. **`05.usage.md`** — CÓMO USAR lo que `03.tasks.md` ya construyó
   (04.implementación no es un archivo, es el estado del código real).
   Se escribe/actualiza recién cuando un grupo de `03.tasks.md` con
   interacción visible para algún usuario (pantalla, comando, botón)
   queda ✅ cerrado y verificado — nunca antes, nunca sobre algo todavía
   sin construir. Responde una sola pregunta: "la funcionalidad ya
   existe, ¿cómo la uso?" — guía paso a paso, en lenguaje llano,
   pensada para que cualquiera (funcional, técnico, soporte, o la IA en
   una sesión futura) la use sin tener que pedir una explicación de
   cero. Nunca duplica el CÓMO SE CONSTRUYE de `02.design.md` ni el QUÉ
   DEBE HACER de `01.requirements.md` — si algo pertenece ahí, se
   referencia (ej. "ver R6"), no se copia. Un grupo de `03.tasks.md`
   sin interacción visible (ej. un detector interno, una guarda que
   corre sola) no necesita entrada en `05.usage.md` — no hay nada que
   un usuario "use" ahí.

   **Regla para la IA**: antes de volver a explicar paso a paso cómo
   usar algo que ya está implementado, consultar `05.usage.md` primero
   — si ya está esa explicación, usarla tal cual en vez de rearmarla de
   cero (ahorra tokens y evita que la explicación de una sesión
   diverja de la de otra). Si la funcionalidad preguntada no está
   todavía en `05.usage.md`, o quedó desactualizada (código real ya no
   coincide), esa es la señal de actualizarlo — primero se corrige el
   documento, después se usa como referencia.

## Regla de oro

Cuando le pidas a la IA que implemente algo, la instrucción siempre
es: **"segui `03.tasks.md`, tarea N"** — no "hacé X" suelto. Si
mientras implementás aparece algo que el spec no contemplaba, se vuelve
a `01.requirements.md`/`02.design.md` primero, se actualiza, y recién
después se sigue con `03.tasks.md`. El código nunca es la fuente de
verdad — el spec sí. Por eso "anchored": todo se ancla ahí, nunca
deriva solo.

## Convención de nombres

Cada spec vive en su propia carpeta, identificada por un código único:

```
SPEC-<ÁREA>-<DDMMAAAA><secuencia>-<slug-corto>
```

`<ÁREA>` agrupa por dominio (`SYS` = plataforma/sistema; se suman más
según haga falta). `<secuencia>` es el número de spec ABIERTA ese día
en esa área (01, 02, ...) — permite más de una por día sin colisión.

## Features documentadas acá

- [`SPEC-SYS-0109202601-administrador-folios/`](SPEC-SYS-0109202601-administrador-folios/) —
  motor de folios de negocio para documentos transaccionales
  (implementado, Grupos A-G completos).
- [`SPEC-API-0409202601-autenticacion-movil/`](SPEC-API-0409202601-autenticacion-movil/) —
  autenticación por token (access+refresh) para que la app Flutter
  autentique contra los mismos usuarios de metadata_stack, sin cookie
  de sesión web (implementado, Grupos A-G completos; `design.md` §4 es
  el contrato de API para el cliente Flutter).
- [`SPEC-SYS-0909202601-framework-navegacion/`](SPEC-SYS-0909202601-framework-navegacion/) —
  documentación retroactiva del framework de navegación (sidebar,
  topbar, footer, menú de usuario) — solo la estructura de navegación,
  no el contenido de cada pantalla del menú. Sin `tasks.md` a propósito
  (nada que construir todavía, es el ancla para futuros cambios).
- [`SPEC-SYS-0909202602-demo-gestion-perros/`](SPEC-SYS-0909202602-demo-gestion-perros/) —
  spec de práctica: catálogo `pty_perros` con motor de estados
  (Activo/Baja/Reactivar), 100% armado con el Motor BC real (BPB +
  Sysadmin), sin publicar a ningún sistema (queda en developer).
- [`SPEC-SYS-0909202604-importacion-actualiza-registros/`](SPEC-SYS-0909202604-importacion-actualiza-registros/) —
  la importación por Excel también actualiza registros existentes (por
  campo identificador configurable), en vez de solo dar de alta
  (implementado, Grupos A-G completos).
- [`SPEC-SYS-0909202605-resumen-seleccion/`](SPEC-SYS-0909202605-resumen-seleccion/) —
  "Resumen de selección": selección de registros (casillero por fila) +
  barra compacta con indicadores (SUMA/PROMEDIO/MÍNIMO/MÁXIMO/CONTEO)
  calculados EXCLUSIVAMENTE sobre lo seleccionado, configurable por
  catálogo/Consulta, independiente del "Total general" ya existente
  (implementado, Grupos A-F completos).
- [`SPEC-SYS-1009202602-endpoint-desde-consulta/`](SPEC-SYS-1009202602-endpoint-desde-consulta/) —
  expone una Consulta (Reporte) como API HTTP propia bajo un prefijo
  reservado, con API key propia por endpoint (sin atarla a ningún
  Usuario). Implementado, y luego extendido en vivo (R67-R76) con
  publicar/despublicar un Endpoint entre ambientes por CLI
  (`mix endpoint.export`/`endpoint.despublicar`, reusando
  `MetaPublicador` directo — nunca `motor.publicar`, que exige el
  header vivo), `/sysadmin/endpoints` disponible en cualquier ambiente,
  botones sin terminal para publicar/despublicar, y autoría (crear/
  editar el endpoint) restringida a local — credenciales y
  documentación quedan universales.
- [`SPEC-TEST-1509202601-seed-masterdata/`](SPEC-TEST-1509202601-seed-masterdata/) —
  herramienta de developer mode (`mix seed.vaciar`/`seed.cargar`/
  `seed.reset`) para reiniciar y repoblar catálogos `pty_*`/
  `demo100_*` de prueba: borrado en orden de dependencias reales
  (ajustable) + carga atómica vía el camino real de alta (TRN/folio/
  reglas), nunca INSERT directo. Implementada y verificada contra
  Postgres real (Grupos A-E completos) — encontró y corrigió en el
  camino un bug real de Postgres (`TRUNCATE` rechaza vaciar una tabla
  referenciada por CUALQUIER otra de la base, sin importar el orden;
  se usa `DELETE` + reinicio de secuencia).
- [`SPEC-SYS-1709202601-sysadmin-usuarios/`](SPEC-SYS-1709202601-sysadmin-usuarios/) —
  documentación retroactiva de `/sysadmin/usuarios` (administrador de
  usuarios de la empresa: alta, roles, capacidades de Sysadmin,
  catálogos por herencia, y Alcance de Datos Empresa/Sucursal/Almacén/
  Unidad de venta), implementado. Incrementos reales (2026-09-17,
  completos): eliminación total de un usuario del ambiente (con
  confirmación y guardas de auto-eliminación/sysadmin de plataforma) +
  picker de doble lista para la pestaña Roles (reemplaza el buscador
  por 2 listas + flechas, con filtro client-side por lista) — ver
  `tasks.md`.
- [`SPEC-SYS-1709202602-sysadmin-catalogos-permisos/`](SPEC-SYS-1709202602-sysadmin-catalogos-permisos/) —
  documentación retroactiva del uso STANDALONE de `CatalogoPermisosLive`
  en `/sysadmin/catalogos/permisos` ("Permission Sets": picker de
  catálogo + navegación por URL), implementado. La matriz de permisos/
  Alcance de Datos en sí (mismo LiveView, también embebido en BC Motor)
  ya está documentada en `SPEC-SYS-1109202605-bc-motor-tab-permisos-
  alcance` — esta spec no la repite, solo cubre lo exclusivo del uso
  standalone. Incremento real completo (2026-09-17): el picker deja de
  perder el filtro al elegir un catálogo/asignar un permiso (el texto
  buscado viaja como query param `?q=` en vez de perderse en el
  remount) + comodín `*` para listar sin substring — ver `tasks.md`.
- [`SPEC-SYS-1809202601-despublicar-catalogo-huerfano/`](SPEC-SYS-1809202601-despublicar-catalogo-huerfano/) —
  mecanismo general para borrar un catálogo "huérfano" (vivo en algún
  ambiente desplegado, ausente en TODOS lados local — típico de un
  rename hecho en el mismo registro en vez de crear+eliminar):
  `mix motor.generar_drop_huerfano <catalogo> --confirmar=<catalogo>`
  genera y corre local la migración de DROP sin exigir header local,
  y `mix motor.despublicar` (sin ningún cambio) la propaga a un
  ambiente puntual. Implementado y verificado en vivo contra `unstable`
  con dos casos reales (`historico`, el caso que lo motivó, y de paso
  `pty_dsd_mat_material_precios`, un catálogo huérfano ajeno que
  bloqueaba todos los deploys).
- [`SPEC-SYS-1809202602-copiar-bc/`](SPEC-SYS-1809202602-copiar-bc/) —
  acción "Copiar" en BC List (junto a Editar/Eliminar) para clonar un
  catálogo maestro simple bajo un nombre nuevo: campos, autómata (si
  lo tiene) y plantilla automática, con el prefijo propio renombrado —
  nunca datos, plantillas custom del Constructor, ni permisos ya
  otorgados (implementado, Grupos A-E completos, verificado contra
  Postgres real).
- [`SPEC-SYS-2209202602-propagacion-artefactos-negocio/`](SPEC-SYS-2209202602-propagacion-artefactos-negocio/) —
  documentación retroactiva de cómo se respalda/propaga un artefacto de
  negocio (catálogo `pty_*`): `mix motor.publicar` deja una copia en un
  GitHub Release (`bc-<catalogo>`) antes de desplegar; ese release se
  reincorpora solo en cada actualización normal del sistema, así que un
  catálogo viaja siempre empaquetado dentro de la actualización
  completa (`mix motor.propagar_extension`), nunca aislado — "todo o
  nada" es diseño, no un descuido. Cierra la nota pendiente de
  `SPEC-SYS-1809202603` (§1). Sin `tasks.md` a propósito (nada que
  construir, comportamiento ya existente).
- [`SPEC-ADN-2209202601-config-sales-unit/`](SPEC-ADN-2209202601-config-sales-unit/) —
  primera spec de área ADN (Administración de Negocio, no plataforma):
  motor de configuración para la app móvil (~120 parámetros, hoy
  serializados en XML) vía Parámetros Base (catálogo cerrado, valida
  nombres) + Perfiles de Configuración (valor compartido, editable una
  sola vez) + dos ejes de asignación independientes — Ventas (Sales
  Unit) y Reparto (Almacén) — cada uno con sus Excepciones puntuales.
  `01.requirements.md`/`02.design.md`/`03.tasks.md` escritos, pendiente
  de ejecución (Grupos A-F).
- [`SPEC-SYS-2509202603-jerarquia-organizacional/`](SPEC-SYS-2509202603-jerarquia-organizacional/) —
  documentación retroactiva de `/sysadmin/jerarquia`: catálogo base
  Empresa → Sucursal → (Unidad de venta / Ubicación de inventario),
  hasta la pantalla del menú "Jerarquía organizacional" — no incluye
  Alcance de Datos por usuario ni Configuración de Sales Unit, que la
  consumen desde specs propias. Sin `tasks.md` a propósito (nada que
  construir, comportamiento ya existente).
