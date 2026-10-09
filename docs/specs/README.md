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

`<ÁREA>` agrupa por dominio (`SYS` = plataforma/sistema; `ARQ` =
Arquitectura; `ADN` = Administración de Negocio; `APP` = aplicación móvil; se suman más según
haga falta). `<secuencia>` es el número de spec ABIERTA ese día
en esa área (01, 02, ...) — permite más de una por día sin colisión.

## Quién puede alterar cada área

Crear, editar, renombrar o borrar cualquier archivo de una carpeta
`SPEC-<ÁREA>-*` está restringido por área:

| Área | Pueden alterarla |
|------|------------------|
| `SYS` | Uriel, Lizbeth |
| `ADN` | Todos |
| `ARQ` | Uriel, Agustín |
| `APP` | Uriel, Jesús |

- **Dónde vive la regla**: `.github/spec-permisos.txt`, con los
  usuarios de GitHub (`Urixsg` = Uriel, `X4GUSS` = Agustín,
  `Lizbeth123143` = Lizbeth, `PRETTYCORE-13` = Jesús). Solo Uriel
  (`ADMIN`) puede cambiar ese archivo, su script y su workflow.
- **Quién la hace cumplir**: el workflow `Permisos de SPEC`
  (`.github/workflows/spec-permisos.yml`) revisa cada commit de cada PR
  y de cada push a `main`, y compara el **autor** del commit contra el
  área de cada archivo que toca. Un renombrado entre áreas necesita
  permiso en las dos.
- **Si no tienes permiso**: el check sale en rojo y el PR no se puede
  integrar. Pide a alguien del área que haga el cambio.
- **Tu correo de git debe estar ligado a tu cuenta de GitHub**: así se
  identifica al autor. Un commit con un correo que GitHub no reconoce
  se rechaza en cualquier área.
- **Área nueva**: antes de abrir la primera spec de un área nueva, hay
  que darla de alta en `.github/spec-permisos.txt` y en la lista de
  áreas de arriba; si no, cualquier commit sobre ella se rechaza.
- Este README y cualquier archivo fuera de una carpeta `SPEC-*` no
  tienen restricción.

## Features documentadas acá

- [`SPEC-SYS-0109202601-administrador-folios/`](SPEC-SYS-0109202601-administrador-folios/) —
  motor de folios de negocio para documentos transaccionales
  (implementado, Grupos A-G completos).
- [`SPEC-APP-0409202601-autenticacion-movil/`](SPEC-APP-0409202601-autenticacion-movil/) —
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
- [`SPEC-ARQ-2209202602-propagacion-artefactos-negocio/`](SPEC-ARQ-2209202602-propagacion-artefactos-negocio/) —
  documentación retroactiva de cómo se respalda/propaga un artefacto de
  negocio (catálogo `pty_*`): `mix motor.publicar` deja una copia en un
  GitHub Release (`bc-<catalogo>`) antes de desplegar; ese release se
  reincorpora solo en cada actualización normal del sistema, así que un
  catálogo viaja siempre empaquetado dentro de la actualización
  completa (`mix motor.propagar_extension`), nunca aislado — "todo o
  nada" es diseño, no un descuido. Cierra la nota pendiente de
  `SPEC-ARQ-1809202603` (§1). Sin `tasks.md` a propósito (nada que
  construir, comportamiento ya existente).
- [`SPEC-SYS-2509202601-consulta-sql/`](SPEC-SYS-2509202601-consulta-sql/) —
  Consulta SQL / "SQL View" (BC tipo 4): un SQL de solo lectura que se
  convierte en vista de Postgres vía migración generada (`pty_sql_*`).
  Uso **Diccionario** (combos de campos referencia, con BC autorizados y
  "Filtrar por diccionario" en SPEC-SYS-1109202601 §2.2) o **Consulta**
  (listado de solo lectura). Validación por Postgres, ejecución de solo
  lectura con tiempo máximo, alcance por columnas de control, GET de API,
  dependencias vía `pg_depend` y publicación con `motor.publicar`.
  Ampliación en curso (§11, grupos K-Q, desde 2026-09-29): tercer uso
  **Servicio**, un SQL con parámetros tipados (incluida lista de
  enteros) que se convierte en una función de Postgres y se ejecuta
  desde las reglas de cualquier BC (`MetaBcApi.ejecutar_servicio/2`,
  dentro de la transacción en curso) o por un Endpoint con credencial.
  Base para "resolvedores" de negocio como el precio, el crédito o las
  promociones. K1 hecho.
- [`SPEC-SYS-2509202602-consulta-ecto/`](SPEC-SYS-2509202602-consulta-ecto/) —
  documentación retroactiva de la Consulta Ecto (Consulta/Reporte, BC de
  solo lectura sobre un catálogo principal + tablas relacionadas): alta
  desde BC List con detección de uniones, editor de 5 pestañas, alcance
  de datos solo sobre el catálogo principal, vista del usuario final y
  `GET /api/:tabla`. `requirements.md` §4 registra sus límites actuales
  sin propuesta (vista sin paginación/búsqueda, tablas fijas después del
  alta, definición que no viaja al publicar). Sin `tasks.md` a propósito
  (nada que construir).
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
- [`SPEC-SYS-2809202601-bc-lista/`](SPEC-SYS-2809202601-bc-lista/) —
  BC Lista (`/sysadmin/bc-list`): documentación retroactiva de la
  pantalla central de artefactos de negocio (árbol, búsqueda, crear,
  ordenar, eliminar, Publicar paquete) + incremento de rapidez: la
  revisión "¿listo para publicarse?" corre en segundo plano una vez por
  visita, y ni buscar ni abrir carpetas consultan la base (R20–R26).
- [`SPEC-SYS-2909202601-prefijo-directorio/`](SPEC-SYS-2909202601-prefijo-directorio/) —
  prefijo de directorio: abreviatura obligatoria y única (1 a 5 letras o
  números, ej. `CH`) de cada carpeta de BC List, con columna propia en la
  tabla; y el directorio viaja completo al publicar (etiqueta,
  visibilidad, ícono, orden y prefijo). No confundir con el prefijo del
  BC (`CH-EMP`), que queda para otra spec. Implementado (Grupos A-F).
- [`SPEC-ADN-2909202601-canal-precio/`](SPEC-ADN-2909202601-canal-precio/) —
  lista de precios de cadena por canal y cascada de precio base por
  producto: lista especial del cliente → lista de cadena del canal →
  lista maestra de la sucursal → "sin precio". La cascada nació como la
  SQL View `pty_sql_materiales_precio_base`, retirada el 2026-09-30 en
  favor del Servicio de SPEC-ADN-2909202602; incluye los detalles de precios y
  sucursales de la lista, y las listas vacías "SIN LISTA ESPECIAL" y "SIN
  LISTA DE CADENA" (las referencias son obligatorias en la plataforma).
  Grupos A-D verificados en dev; pendiente la publicación. La vista se
  retira cuando exista el servicio de SPEC-ADN-2909202602.
- [`SPEC-ARQ-3009202602-propagacion-produccion-clientes/`](SPEC-ARQ-3009202602-propagacion-produccion-clientes/) —
  extiende `SPEC-ARQ-1809202603` (y la pantalla `PropagacionLive` que
  ya existe) para propagar `stable` a VARIOS clientes reales a la vez,
  por oleadas (piloto primero, resto después). La aprobación de un
  segundo administrador se resuelve con "environment protection rules"
  nativas de GitHub Actions (ambiente `clientes`, revisores
  obligatorios) — sin tabla ni comando de aprobación propios; el
  registro es un archivo `.jsonl` de solo-agregar, sin ninguna
  migración de Ecto. Transforma un documento externo pegado por el
  usuario (30-09-2026), afinado con un prototipo clicable del mismo
  equipo — `01.requirements.md` §1.1 documenta qué se adoptó (selección
  múltiple, oleadas, aprobación vía GitHub, confirmación por cliente) y
  qué se rechazó (Oban, tabla de auditoría, correo/WhatsApp, acceso
  directo a la API de Kubernetes). `01.requirements.md`/`02.design.md`/
  `03.tasks.md` escritos, pendiente de ejecución (Grupos A-I).
- [`SPEC-ADN-2909202602-servicio-precio/`](SPEC-ADN-2909202602-servicio-precio/) —
  servicio de precio de venta: recibe dirección de entrega, productos y
  fecha, y deduce cliente, canal y sucursal. Regresa por producto el
  precio por caja sin impuestos, su nivel, su lista y un estado (`ok`,
  `sin_precio` o `direccion_invalida`). Punto único para el pedido, la
  app y las integraciones; crecerá con descuentos e impuestos. En curso
  desde 2026-09-30 (el uso Servicio de SPEC-SYS-2509202601 ya existe).
- [`SPEC-ADN-0710202601-pedido-renglones-precio/`](SPEC-ADN-0710202601-pedido-renglones-precio/) —
  renglones del pedido de venta (`pty_dsd_pedidos`) y procedimiento de
  precios configurable con tipos de paso cerrados (precio, descuentos
  inactivos por ahora, IEPS, IVA, total), calculado al guardar en la regla
  POST y congelado al confirmar. Estados Captura → Confirmado →
  Remisionado / Cancelado; folio del administrador de folios. Aprobada el
  2026-10-08; Grupos A-E y F2-F4 hechos, F1 (prueba en pantalla) en curso
  y G (cierre) pendiente. Depende de SPEC-ADN-0710202602 y
  SPEC-SYS-0710202602 (las dos construidas).
- [`SPEC-ADN-0710202602-datos-fiscales-impuestos/`](SPEC-ADN-0710202602-datos-fiscales-impuestos/) —
  tipos y tasas de impuesto con vigencia, datos fiscales de material,
  cliente, dirección y sucursal, catálogo de códigos postales del SAT,
  regla completa del 8 % de frontera y Servicio de impuestos de venta
  (`impuestos-venta`). Incluye el tipo de parámetro `lista_decimales`
  para SPEC-SYS-2509202601. Grupos A-G cerrados y verificados en dev el
  2026-10-07 (95,748 CP cargados con script SQL, servicio 23/23 casos,
  Endpoint probado por curl); falta publicar, ver G2.
- [`SPEC-SYS-0710202602-post-con-renglones-guardados/`](SPEC-SYS-0710202602-post-con-renglones-guardados/) —
  la regla POST del encabezado de un maestro-detalle corre al final,
  cuando sus renglones nuevos, editados y quitados ya están guardados,
  por cualquier camino (pantalla, API, Endpoints, importación). Opción
  `escribir_renglones` del motor para que cada llamador escriba igual que
  hoy. Prerrequisito del cálculo de precios del pedido
  (SPEC-ADN-0710202601). Grupos A-F cerrados el 2026-10-07 (12 pruebas
  nuevas, suite 1151/1155 con las 4 fallas conocidas de Windows).
- [`SPEC-SYS-0810202601-permisos-renglones-y-alta/`](SPEC-SYS-0810202601-permisos-renglones-y-alta/) —
  los permisos de cambiar y quitar renglones se revisan con el estado
  actual del documento (no con el guardado en cada renglón); el alta de un
  usuario solo acepta campos editables (encabezado y renglones); una
  referencia inexistente se rechaza con el campo en lugar de un error
  interno. Encontrado por las pruebas adversas de SPEC-ADN-0710202601.
  Grupos A-F cerrados el 2026-10-08 (8 pruebas nuevas; pruebas adversas del pedido sin residuo).
- [`SPEC-SYS-3009202602-endpoints-externos/`](SPEC-SYS-3009202602-endpoints-externos/) —
  Endpoints Externos (antes "Acciones externas"): llamadas configuradas a
  APIs de otros sistemas, con credencial cifrada, botón en la ficha,
  llamada desde reglas y bitácora. Documentación retroactiva de lo que
  existe desde 2026-08-06, más lo nuevo: guardar datos de la respuesta en
  el registro (mapeo), rechazo con el mensaje del sistema externo,
  respuesta en la bitácora (30 días) y ejecución en segundo plano con
  reintentos. Documentada, sin programar. La sincronización masiva de
  catálogos queda para otra SPEC.
- [`SPEC-SYS-0710202601-tepache/`](SPEC-SYS-0710202601-tepache/) —
  Tepache (`/sysadmin/tepache`, `mix motor.tepache`/
  `motor.tepache.importar`): bundles de previsualización entre
  desarrolladores vía GitHub Releases (`TEPACHE-NNNNNN`), importados al
  Postgres local sin deploy y sin conceder permisos a ningún rol.
  Documentación retroactiva más requisitos nuevos: el export se
  rechaza si falta seleccionar alguna dependencia (R9); el import solo
  aplica los catálogos del bundle (R14.1); barras de progreso por
  etapas al exportar e importar, en segundo plano (R20, R22); y un
  import que falla deshace lo que hizo ese intento — migraciones,
  archivos, metadata y permisos —, sin revertir nada si no es seguro
  (R21). Implementado y verificado (Grupos A-E completos).
