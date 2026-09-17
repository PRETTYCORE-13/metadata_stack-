# Tasks — Crear endpoint a partir de una Consulta

Cada tarea es chica y verificable por sí sola (compila, corre, un test
o una prueba manual puntual pasa) antes de pasar a la siguiente. Se
implementa con "seguí tasks.md, tarea N" — nunca todas de una sin que
se pida explícitamente.

## Grupo A — Modelo de datos

- [x] **A1.** Migración `meta_schema_consulta_endpoint`: columnas según
      design.md §1 (`meta_schema_consulta_id` FK único, `nombre`,
      `metodo`, `ruta`, `descripcion`, `parametros` jsonb, `estado`
      default `"borrador"`, `empresa_id` FK, `api_key_hash`,
      `api_key_sufijo`, guids, timestamps), índice único
      `(metodo, ruta)` sobre filas con `delete_guid is nil`.
      Verificable: `mix ecto.migrate` limpio en dev y test.

- [x] **A2.** Schema `MetaSchema.ConsultaEndpoint` + changeset:
      valida `metodo in ["get","post"]`, `ruta` con
      `^[a-z0-9-]+$`, `estado in ["borrador","publicado"]`,
      `unique_constraint` sobre `meta_schema_consulta_id` y sobre
      `(metodo, ruta)`. Verificable: changeset inválido para una ruta
      con mayúsculas o con `/`.

- [x] **A3.** Validación R8.1 en el changeset: cada elemento de
      `parametros` (`"campo"`) DEBE existir en `consulta.campos` con
      `"es_parametro": true` — si no, error en ese campo del changeset
      (nunca se persiste el resto del formulario). Test unitario: un
      `parametros` con un campo que ya no es Parámetro vigente falla
      el changeset; uno con todos vigentes pasa.

- [x] **A4.** Migración + schema `MetaSchema.ConsultaEndpointLog`
      (design.md §1.1): `meta_schema_consulta_endpoint_id`,
      `fecha_hora`, `empresa_id` (entero, sin FK viva), `ip`, `metodo`,
      `resultado_http`, `duracion_ms`, `cantidad_registros`.
      Verificable: `mix ecto.migrate` limpio, insert directo de una
      fila de prueba vía `Repo.insert` en test.

## Grupo B — Contexto `MetadataApp.ConsultaEndpoints`

- [x] **B1.** `obtener_por_consulta/1`, `crear_o_actualizar/2` (usa el
      changeset de A2/A3). Test unitario: crear, releer, actualizar
      conservando `estado`.

- [x] **B2.** `publicar/1`: genera key (`:crypto.strong_rand_bytes(32)
      |> Base.url_encode64(padding: false)`), calcula
      `api_key_hash`/`api_key_sufijo`, `estado = "publicado"`, devuelve
      `{:ok, endpoint, key_en_claro}`. Test unitario: la key devuelta
      hashea igual a `endpoint.api_key_hash`; `key_en_claro` termina en
      `endpoint.api_key_sufijo`.

- [x] **B3.** `despublicar/1` (`estado = "borrador"`, conserva
      hash/sufijo) y `regenerar_api_key/1` (mismo cálculo que B2,
      reemplaza hash/sufijo). Test unitario: tras regenerar, el hash
      viejo ya no matchea ninguna key emitida antes.

- [x] **B4.** `obtener_publicado(metodo, ruta)` — solo devuelve algo
      con `estado == "publicado"`; `nil` para borrador o inexistente.
      Test unitario cubriendo los 3 casos.

- [x] **B5.** `probar/3` -- signatura final
      `probar(consulta, scope, overrides_parametro \\ %{})` (sin
      `endpoint`: nada de su config afecta la ejecución, solo delega en
      `MetaConsultas.ejecutar/6` con el `scope` REAL de quien prueba).
      Test unitario con datos reales.

## Grupo C — Alcance por empresa fija (MetaConsultas)

**Simplificación encontrada durante la implementación (2026-09-10):**
`ejecutar/6` ya calcula `total_filas` (`Repo.aggregate(query, :count)`)
sobre la query filtrada ANTES del limit/offset de paginación — ese
valor sirve tal cual para `"meta".total` (R17), así que no hace falta
un `MetaConsultas.contar/4` aparte (se quita del plan original, ver
design.md §3/§4 actualizados).

- [x] **C1.** Nueva cláusula de `aplicar_alcance_de_datos/4` para
      `scope = {:empresa_fija, empresa_id}` (junto a las ya existentes
      `:sistema`/`nil`/`%Scope{}`) — reusa `con_columna_alcance/5` con
      el mismo criterio permisivo que `aplicar_where_de_alcance(:empresa,...)`
      pero comparando contra el `empresa_id` recibido en vez de
      `scope.empresa_activa.id`; no-op si `catalogo_base` no tiene
      columna `empresa_id`. Test unitario con `meta_fixture_equipo`
      (sin la columna) confirmando el no-op.

- [x] **C2.** Prueba real end-to-end: se agregó una columna real
      `empresa_id` a `meta_fixture_cliente` (migración dedicada,
      `20260910120200`, solo para poder probar esto dentro del repo sin
      depender de un catálogo generado en dev) y se probó `ejecutar/6`
      con `scope = {:empresa_fija, empresa_id}` sobre datos de 2
      empresas reales en la misma tabla — cada una ve solo sus propias
      filas + las que tienen `empresa_id` nil (mismo criterio permisivo
      que branch/sales_unit/inventory_location), y `total_filas`
      coincide exactamente. Los 28 tests de `meta_consultas_test.exs`
      (incluidos los preexistentes) pasan sin tocar sus llamadas
      actuales.

## Grupo D — Ruteo y controller público

**Nota de implementación (2026-09-10):** el pipeline final se llama
`:api_consulta_endpoint` (no `:api`) -- SOLO `accepts`, sin
`fetch_session`/scope de usuario, para que quede explícito que esta
ruta nunca corre con identidad de admin. `MetaConsultas.ejecutar/6`
ganó soporte a `opciones[:timeout]` (ms, pasado a `Repo.all`/
`Repo.aggregate`) para D4, sin cambiar el comportamiento default de
nadie más. La construcción de `overrides_parametro` (D3) vive en
`ConsultaEndpoints.construir_overrides/3` (no en el controller), con
una convención de nombres externos documentada ahí: la clave externa
de un parámetro simple es su `clave_campo` tal cual; uno ACOTADO
(rango) usa `"<clave>_desde"`/`"<clave>_hasta"`.

- [x] **D1.** Scope `/api/consultas/*ruta` (GET y POST) en
      `router.ex`, `pipe_through :api_consulta_endpoint`, apuntando a
      `MetadataAppWeb.Api.ConsultaEndpointController.invocar/2`
      (design.md §3). Verificado: `mix phx.routes` muestra las 2 rutas
      nuevas, antes del scope `/api` genérico.

- [x] **D2.** `invocar/2` paso 2-3: resolver `metodo`+`ruta`, 404 si no
      hay endpoint publicado; extraer `Authorization: Bearer <key>`,
      hashear y comparar con `ConsultaEndpoints.api_key_valida?/2`
      (`secure_compare/2` internamente), 401 si falta/no matchea/viene
      mal formado o por query string. Test real (`ConnCase`, Postgres
      real): sin header → 401; header con key incorrecta → 401;
      endpoint en borrador → 404 aunque la key sea correcta; ruta
      inexistente → 404.

- [x] **D3.** `invocar/2` arma `overrides_parametro` vía
      `ConsultaEndpoints.construir_overrides/3` -- solo con los campos
      de `endpoint.parametros` (ignora cualquier otro, incluido un
      `empresa_id` que llegue en el body/query — R13), 400 listando los
      obligatorios faltantes. Test real: falta un obligatorio → 400 con
      el nombre del campo; un `empresa_id` en query string no cambia la
      empresa de los resultados.

- [x] **D4.** `invocar/2` paginación (`pagina`/`por_pagina` con default
      50 / tope 200, constantes del controller) y timeout de ejecución
      (10s, vía `opciones[:timeout]` de `ejecutar/6` → `Repo`, 504 JSON
      si Postgrex cancela por exceso). Test real: pedir `por_pagina`
      por encima del tope devuelve como máximo el tope; `pagina`/
      `por_pagina` inválidos (no numérico, negativo) caen a los
      defaults en vez de crashear.

- [x] **D5.** Respuesta `%{"data" => filas, "meta" => %{...}}` (R11,
      R17) — GET con parámetros por query string y POST con body JSON
      dan el mismo resultado para el mismo valor. Test real con datos
      de 2 empresas en `meta_fixture_cliente` (columna `empresa_id`
      agregada en el Grupo C), confirmando que solo salen filas de la
      empresa del endpoint.

- [x] **D6.** `invocar/2` paso 8: inserta la fila de
      `ConsultaEndpointLog` al final de cada llamada (éxito o error a
      partir de tener el endpoint resuelto), sin bloquear la respuesta
      si el insert de auditoría falla. Test real: una llamada exitosa y
      una con 401 dejan cada una su fila; ninguna columna contiene la
      key ni los valores de los parámetros.

## Grupo E — UI en `ConsultaEditorLive`

**Bug real encontrado y corregido acá:** `parametros_elegibles_endpoint`
se calculaba una sola vez en `cargar/2` (mount) y quedaba
DESACTUALIZADO en cuanto el admin marcaba/desmarcaba "es_parametro"
desde la pestaña Get Config sin recargar la página completa — la
pestaña Endpoint API mostraba una lista de parámetros elegibles vieja.
Corregido recalculándolo también dentro de `guardar_campos/3` (el
mismo punto donde ya se reasignan `:consulta`/`:campos`). Encontrado
por el test E2E de este grupo, no por un test unitario aislado.

- [x] **E1.** Pestaña nueva "Endpoint API" (`cambiar_tab`) con el
      formulario base: nombre, método, ruta (prefijo fijo no editable
      delante del input), descripción. `handle_event("guardar_endpoint", ...)`
      persiste vía `ConsultaEndpoints.crear_o_actualizar/2`. La
      validación de `(metodo, ruta)` duplicado ya está cubierta a nivel
      changeset (Grupo A); acá se verificó con datos reales que Guardar
      funciona de punta a punta desde la UI real.

- [x] **E2.** Checkboxes de parámetros elegibles (campos con
      `es_parametro: true`, mismo criterio que `MetaConsultas.
      campos_elegibles_*/1`) + checkbox Obligatorio por cada uno.
      Verificado con datos reales (LiveViewTest): marcar "es_parametro"
      vía el evento real de Get Config, guardar el endpoint con ese
      parámetro activo+obligatorio, y ver la clave reflejada en la
      pestaña.

- [x] **E3.** Botón **Probar**: mini-formulario con un input por
      parámetro configurado (usa la MISMA convención de nombres
      externos que el controller público, vía
      `ConsultaEndpoints.construir_overrides/3` -- no hay dos caminos
      distintos para "lo que se prueba" y "lo que respondería" la
      llamada real), ejecuta `ConsultaEndpoints.probar/3` con el
      `current_scope` real del admin. Verificado con datos reales:
      funciona con el endpoint todavía en borrador (R28).

- [x] **E4.** Botones **Publicar**/**Despublicar**/**Regenerar** +
      franja con método+ruta completa — al publicar/regenerar, aviso
      destacado mostrando la key COMPLETA una única vez; en cualquier
      otra carga de la pantalla (remount de la LiveView, simulando
      recargar), se muestra enmascarada (`api_key_sufijo`). Verificado
      con datos reales: la key mostrada al publicar NUNCA vuelve a
      aparecer tras remontar la vista; regenerar produce una key
      distinta.

- [x] **E5.** Vista de **Documentación** (solo lectura, visible solo
      con el endpoint publicado): método, ruta, esquema de
      autenticación (Bearer), tabla de parámetros, forma de la
      paginación, ejemplo de respuesta — nunca incluye la key.
      Verificado con datos reales.

- [x] **E5.1** (agregado 2026-09-11, a pedido explícito — "que se vea
      el json que pueden enviar"). **Ejemplo de solicitud** en la misma
      sección de Documentación: GET arma el query string completo con
      los parámetros configurados + `pagina`/`por_pagina`; POST arma el
      body JSON — mismos nombres externos que interpreta
      `ConsultaEndpoints.construir_overrides/3` (clave / `clave_desde`+
      `clave_hasta` para un parámetro acotado), con un valor de ejemplo
      razonable por tipo. Verificado con datos reales (LiveViewTest):
      tras publicar, aparece "Ejemplo de solicitud" con
      `GET /api/consultas/<ruta>` y el parámetro namespaced en el query
      string.

- [x] **E6.** (R1.1, agregado 2026-09-11, a pedido explícito) Atajo
      "+ Endpoint" en `BcListLive`, por fila de catálogo normal — arma
      la Consulta interna (`schema_visible: false`) sin pasar por el
      modal "Nueva consulta" y aterriza directo en la pestaña Endpoint
      API (`ConsultaEditorLive.mount/3` ahora lee `params["tab"]`).
      Verificado con datos reales (LiveViewTest): el clic crea el
      header oculto tipo 3 sobre el catálogo elegido y redirige a
      `.../consulta?tab=endpoint_api`, que renderiza esa pestaña ya
      seleccionada.

## Grupo F — Verificación end-to-end y regresión

- [x] **F1.** Prueba real completa (Postgres real, `ConnCase`): 3
      registros reales, paginado con `por_pagina=2` entre página 1 y 2
      con el mismo Bearer válido — `data`/`meta` correctos en las dos,
      sin registros repetidos entre páginas.

- [x] **F2.** Prueba real de seguridad HTTP: regenerar la key invalida
      la anterior de inmediato (401 con la vieja, 200 con la nueva);
      despublicar con key válida → 404 (D2); un `empresa_id` en query
      string nunca cambia la empresa de los resultados (D3).

- [x] **F3.** Prueba real de auditoría: una llamada exitosa y una con
      401 dejan cada una su fila en `ConsultaEndpointLog`, con
      `empresa_id`/`resultado_http` correctos y ninguna columna con la
      key ni los valores de los parámetros (cubierto en D6).

- [x] **F4.** Confirmado (`mix test` de `consulta_controller_test.exs`,
      la suite ya existente de la ruta implícita): 5/5 tests siguen
      pasando sin cambios — esta spec es aditiva, no tocó esa ruta ni
      su controller.

**Verificación de regresión general:** suite completa (`mix test`) —
573 tests, mismos 20 fallos preexistentes y no relacionados de antes
de esta spec (Caddy, IdentificadoresTransaccionales/folios,
UsuariosEmpresaLive, MetaTepache, Release, un test de `CatalogoLiveConsultaTest`
sobre modo de parámetro Fecha) — ninguno nuevo introducido por este
trabajo.

## Grupo G — Credenciales múltiples con alcance por campo (R19.1, R42-R46)

Reemplaza el modelo "1 endpoint = 1 key" (Grupos A-F) por "1 endpoint =
N credenciales". Sin datos reales en producción todavía (spec recién
construida) — no hace falta migrar datos, solo sacar las columnas
viejas.

- [x] **G1.** Migración: quitar `api_key_hash`/`api_key_sufijo` de
      `meta_schema_consulta_endpoint` (ya no se usan ahí). Actualizar
      `MetaSchema.ConsultaEndpoint` (schema) sacando esos dos campos.

- [x] **G2.** Migración + schema `MetaSchema.ConsultaEndpointCredencial`
      (design.md §1.2): `meta_schema_consulta_endpoint_id` (FK, SIN
      unique — muchas por endpoint), `nombre`, `api_key_hash` (unique
      index), `api_key_sufijo`, `campos_permitidos` ({:array, :string}),
      `estado` ("activa"|"revocada", default "activa"), guids,
      timestamps. Changeset valida `campos_permitidos` contra los
      campos VISIBLES de la Consulta (mismo criterio R8.1, pero con
      "visible" en vez de "es_parametro"). Test unitario: changeset
      rechaza un campo que no es visible.

- [x] **G3.** Migración: agregar
      `meta_schema_consulta_endpoint_credencial_id` (entero, sin FK
      viva) a `meta_schema_consulta_endpoint_log`. Actualizar
      `MetaSchema.ConsultaEndpointLog` (schema).

- [x] **G4.** `ConsultaEndpoints`: `crear_credencial/3`,
      `regenerar_api_key_credencial/1`, `revocar_credencial/1`,
      `listar_credenciales/1`, `resolver_credencial/2` (hash + lookup
      indexado + `secure_compare/2`) — sacar `api_key_valida?/2` y la
      generación de key de `publicar/1` (ya no aplica, publicar/1 pasa
      a ser un simple toggle de `estado`). Tests unitarios: crear con
      campos_permitidos inválidos falla; regenerar una credencial no
      invalida las demás del mismo endpoint; revocar una no afecta a
      las otras; `resolver_credencial/2` no matchea una revocada.

- [x] **G5.** Controller: reemplazar el chequeo de key única por
      `resolver_credencial/2`; filtrar cada fila de `"data"` a
      `Map.take(fila, credencial.campos_permitidos)` antes de
      responder; auditoría (D6) suma `credencial_id`. Test real: dos
      credenciales del mismo endpoint con distintos `campos_permitidos`
      -- cada una solo ve sus propios campos en la respuesta real.

- [x] **G6.** UI (`ConsultaEditorLive`, pestaña Endpoint API): sección
      "Credenciales" (lista de tarjetas + "Ver permisos"/"Regenerar"/
      "Revocar") reemplaza el bloque único de key; modal
      "+ Nueva credencial" (nombre + checkboxes de campos visibles,
      cerrado con `phx-click-away` -- nunca `stopPropagation`, mismo
      criterio que ya aprendió esta spec con el bug real del checkbox
      de selección). Verificado con datos reales (LiveViewTest): crear,
      regenerar y revocar una credencial de punta a punta.

- [x] **G7.** Verificación end-to-end: reescribir/extender los tests
      de los Grupos B/D/E que usaban `publicar/1`/`regenerar_api_key/1`
      devolviendo una key de ENDPOINT para que ahora pasen por una
      credencial — suite completa sin regresiones.

## Grupo H — Grandes volúmenes de resultados (R35-R41)

Cursor se agrega sin tocar `pagina`/`por_pagina` (decisión explícita).
Job asíncrono con Oban (dependencia nueva).

- [x] **H1.** Agregar dependencia `oban` (mix.exs) + su migración
      estándar (`Oban.Migration.up/1`) + configuración mínima (repo,
      una cola). Verificado: `mix ecto.migrate` limpio en dev/test,
      `Oban` arranca con la app (supervisor), `testing: :inline` en
      `config/test.exs`. **Incidente real durante esta tarea**: al
      corregir la versión de esquema de Oban (12 vs. 14 que exige la
      lib instalada) se probó `mix ecto.rollback --to <migración>`
      pensando que solo revertía esa migración puntual -- deshizo
      bastantes más migraciones viejas de las esperadas (varias tablas
      `_prueba`) antes de chocar con una irreversible y frenarse.
      Corregido de inmediato con `mix ecto.migrate` hacia adelante en
      dev y test (schema 100% restaurado, usuarios/empresa/endpoint ya
      creados confirmados intactos) + una migración NUEVA hacia
      adelante (`20260911100100`) para llevar Oban de v12 a v14, sin
      tocar nada hacia atrás -- la forma correcta que debí usar desde
      el principio.

- [x] **H2.** `MetaConsultas.ejecutar/6`: nueva opción
      `opciones[:despues_de_id]` (keyset -- `WHERE id > ^id ORDER BY id`,
      sin `Repo.aggregate(:count)` cuando este modo está activo) —
      aditivo, `limit:`/`offset:`/`timeout:` existentes sin tocar. Test
      unitario real: paginar por cursor entre 3 lotes (5 filas,
      límite 2) trae las 5 exactamente una vez, sin duplicados ni
      huecos, y un cuarto pedido después de la última da `[]`; con
      `orden_por` configurado en la Consulta, el modo cursor lo ignora
      y ordena por `id` igual.

- [x] **H3.** Controller: si llega `cursor` en la solicitud (aunque
      venga vacío, `?cursor=`), arma `opciones[:despues_de_id]` en vez
      de `limit:`/`offset:`, responde
      `"meta": {"cursor_siguiente":, "tiene_mas":}` (sin `"total"`).
      Sin `cursor`, comportamiento actual intacto (verificado con test
      real). Test real: 3 llamadas encadenadas por cursor (`limite=2`
      sobre 5 filas) traen las 5 exactamente una vez, sin duplicados ni
      huecos, `tiene_mas: false` en la última; un cursor mal formado
      responde 400 sin ejecutar nada.

- [x] **H4.** Migración + schema `MetaSchema.ConsultaEndpointJob`
      (design.md §5.2.2): estado, oban_job_id, archivo_resultado,
      cantidad_registros, error, timestamps. Migrado en dev y test.

- [x] **H5.** `MetadataApp.Workers.ConsultaEndpointJob` (Oban.Worker) --
      decisión durante la implementación (ver design.md §5.2.2): reusa
      el loop por cursor de H2 en vez de `Repo.stream/2` (evita
      exponer la query interna de `MetaConsultas`), nunca más de un
      lote de 5.000 filas en memoria a la vez; filtra por
      `campos_permitidos` de la credencial ANTES de escribir cada
      línea; escribe NDJSON incremental vía `MetadataApp.ArtefactosJob`.
      **Bug real encontrado y corregido acá**: `ConsultaEndpoints.
      crear_job/3` devolvía el struct del job capturado ANTES de
      `Oban.insert/1` -- bajo `testing: :inline`, el job ya corrió
      sincrónico para ese punto, así que el struct viejo seguía
      diciendo "pendiente" aunque la fila real ya estuviera
      "completado". Corregido re-leyendo el job de la base al final de
      `crear_job/3` en vez de devolver el struct en memoria.

- [x] **H6.** Rutas + controller: `POST /api/consultas/:ruta/jobs`
      (encola, `202` inmediato) y
      `GET /api/consultas/:ruta/jobs/:job_id` (estado; si completado,
      sirve el NDJSON vía `send_file/5`) -- rutas literales de un solo
      segmento, ANTES del splat `/*ruta` existente. Mismo auth por
      credencial que la vía síncrona (`ConsultaEndpoints.
      obtener_publicado_por_ruta/1`, sin filtrar por método -- un Job
      es un recurso propio del endpoint, no de su verbo síncrono). Test
      real (Oban `testing: :inline`, `config/test.exs`): encolar,
      confirmar "completado", descargar el NDJSON y decodificar cada
      línea confirmando las filas esperadas; un job de OTRO endpoint
      con una credencial ajena → 404.

- [x] **H7.** Verificación end-to-end + regresión: suite completa —
      590 tests, mismos 20 fallos preexistentes de siempre, sin
      regresiones nuevas. Confirmado con datos reales: un endpoint SIN
      `cursor` en la solicitud sigue devolviendo `pagina`/`por_pagina`/
      `total` exactamente igual que antes de este grupo (R37).

## Grupo I — Sección dedicada "Endpoints" (R47-R51, agregado 2026-09-14)

- [x] **I1.** Contexto: `ConsultaEndpoints.listar_todos/0` (todos los
      endpoints no borrados, precargados con `consulta: :header`) y
      `ConsultaEndpoints.eliminar/1` (borra el Header oculto vía
      `MetaSchemaContext.eliminar_header/1` -- cascada real ya existente
      por FK `on_delete: :delete_all` Header → Consulta →
      ConsultaEndpoint → ConsultaEndpointCredencial, sin código nuevo de
      borrado en cascada).

- [x] **I2.** Router: `/sysadmin/endpoints` (`:index`),
      `/sysadmin/endpoints/nuevo` (`:nuevo`),
      `/sysadmin/endpoints/:nombre` (`:editar`, ruteada por el
      `schema_context_name` del Header oculto) -- las 3 dentro del
      mismo bloque `if Application.compile_env(:metadata_app,
      :bpb_habilitado)` que ya gateaba `/sysadmin/bc-list/*`, mismo
      criterio de disponibilidad (nada de esto existe en un release de
      producción compilado).

- [x] **I3.** Nuevo módulo `MetadataAppWeb.Sysadmin.EndpointsLive`
      (3 vistas por `@live_action`, ver design.md §5): `:index` (tabla +
      Eliminar), `:nuevo` (picker catálogo base + tabla detalle
      opcional con vista previa en vivo de `detectar_union/2` vía
      `phx-change`, R48), `:editar` (Campos + Configuración + Probar +
      Publicación + Credenciales + Documentación, todo en una sola
      pantalla sin tabs). El bloque Configuración/Probar/Publicación/
      Credenciales/Documentación se migró tal cual desde el
      `panel_endpoint_api/1` retirado de `ConsultaEditorLive` (mismos
      `handle_event`, mismo HTML) -- sin cambio de comportamiento.

- [x] **I4.** Retirado el atajo "+ Endpoint" de `BcListLive`
      (`crear_endpoint_directo` + su botón) y la pestaña "Endpoint API"
      completa de `ConsultaEditorLive` (tab, panel, handlers,
      `parametros_elegibles_endpoint/1`, `campos_visibles_endpoint/1`,
      `asignar_endpoint_y_credenciales/2` y toda la documentación
      inline que sostenían) -- `EndpointsLive` es ahora el único camino.
      Menú "Endpoints" (agregado en una tanda anterior a los 16 `@menu`
      duplicados de Sysadmin) apunta a `/sysadmin/endpoints`.

- [x] **I5.** Tests: `test/metadata_app_web/live/sysadmin/
      endpoints_live_test.exs` (nuevo, 5 tests -- `:index` vacío,
      `:nuevo` sin detalle crea Consulta+endpoint borrador y aparece en
      `:index` de inmediato (R49), `:nuevo` con tabla detalle SIN unión
      detectable no crea nada, flujo completo de `:editar` (Campos →
      Guardar → Probar → Publicar → Credenciales → Eliminar), Eliminar
      desde `:index`). Borrados `bc_list_live_crear_endpoint_directo_test.exs`
      y `consulta_editor_live_endpoint_api_test.exs` (probaban
      exclusivamente las dos entradas retiradas). Suite completa: 593
      tests, mismos 20 fallos preexistentes de siempre (Caddy,
      MetaTepache, UsuariosEmpresaLive, CatalogoLiveConsulta,
      IdentificadoresTransaccionales/Enganche, ReleaseTest) -- cero
      regresiones nuevas.

## Grupo J — Alta de registros vía POST (R54-R58, agregado 2026-09-14)

- [x] **J1.** Migración `20260914130000_agregar_alta_a_consulta_endpoint.exs`
      (`permite_alta` boolean default false, `campos_alta` array de
      string default []) -- aplicada en dev y test. `ConsultaEndpoint`
      castea ambos + `validar_campos_alta_vigentes/2` (mismo criterio
      que `validar_parametros_vigentes/2`, contra los campos REALES del
      catálogo base vía `MetaSchemaContext.listar_detalles/1`, no
      contra los de la Consulta).

- [x] **J2.** `ConsultaEndpoints.crear_registro/3` -- resuelve el
      módulo Ecto real (`MetaSchemaContext.modulo_por_nombre/1`),
      recorta `attrs_externos` a `campos_alta` (R55), estampa
      `empresa_id` del endpoint SIEMPRE pisando cualquier valor externo
      (R57), y llama `CatalogoGenerico.crear(modulo, :sistema, attrs)`
      -- MISMO camino que un alta manual real (motor de estados, folio/
      TRN, R56). Verificado con datos reales: un catálogo sin ningún
      estado configurado rechaza con `:motor_no_configurado` (regla
      preexistente de `crear_simple_o_rechazar/4`, no se reinventó
      nada) en vez de insertar en silencio.

- [x] **J3.** `ConsultaEndpointController` -- dispatch nuevo en
      `ejecutar/5`: si `metodo == "post" and permite_alta`, el body
      nunca se interpreta como filtros, va a `ejecutar_alta/5` →
      `crear_registro/3`. Éxito → `201 {"data": {"id": <id>}}`; fallo →
      `422 {"error": "<mensaje>"}` (`mensaje_error_alta/1` traduce un
      `Ecto.Changeset` real o hace `inspect/1` de cualquier otro
      motivo).

- [x] **J4.** UI en `EndpointsLive :editar` -- tarjeta "Alta de
      registros" (toggle `permite_alta` + checkboxes de campos reales
      del catálogo base, visible solo si `metodo == "post"`), evento
      `guardar_alta`. Documentación bifurca por completo en modo alta
      (lista de `campos_alta` en vez de parámetros de filtro, ejemplo
      de body de inserción real vía `ejemplo_alta/3` +
      `documentacion_ejemplo_alta/0`).

- [x] **J5.** Tests: `consulta_endpoint_controller_alta_test.exs`
      (nuevo, 5 tests con datos reales -- inserta un registro real y
      nace en el estado inicial del motor; `empresa_id` siempre es la
      del endpoint aunque el body mande otra; un campo real NO
      habilitado en `campos_alta` se ignora aunque el caller lo mande;
      falta un campo obligatorio del catálogo → 422 sin insertar nada;
      catálogo sin motor de estados configurado → 422, no un insert
      silencioso). Suite completa verificada sin regresiones nuevas
      sobre el mismo baseline de 20 fallos preexistentes.

## Grupo K — Renglones de detalle en el alta (R59-R61, agregado 2026-09-14)

- [x] **K1.** Migración `20260914140000_agregar_renglones_alta_a_consulta_endpoint.exs`
      (`renglones_alta` array de map, default []) -- aplicada en dev y
      test. Changeset valida cada entrada contra
      `MetaSchemaContext.listar_catalogos_detalle/1` (catálogo detalle
      REAL de `catalogo_base`) + `listar_detalles/1` de ese catálogo
      (campos reales).

- [x] **K2.** `ConsultaEndpoints.crear_registro/3` arma
      `opciones[:renglones]` (`renglones_spec_desde_externos/2`) a
      partir de `attrs_externos` -- reusa `CatalogoGenerico.crear/4` +
      `opciones[:renglones]`, el MISMO mecanismo ya usado por
      `catalogo_controller.ex`/`ficha_live.ex`/`meta_importacion_datos.ex`,
      sin código de alta atómica nuevo.

- [x] **K3.** UI en `EndpointsLive :editar` -- sub-sección "Renglones"
      dentro de "Alta de registros" (solo si `catalogo_base` tiene
      catálogos detalle reales), un bloque de checkboxes por catálogo
      detalle. Documentación agrega el bloque "Renglones · &lt;etiqueta&gt;"
      + el body de ejemplo incluye la clave del catálogo detalle.

- [x] **K4. Bug real encontrado y corregido durante la verificación**:
      `campos_reales_alta/1` leía `props["obligatorio"]` para el badge
      "Obligatorio en el catálogo" -- esa clave NO EXISTE en un
      catálogo real generado desde BC List (usa `"opcional"`,
      invertido). Corregido a `props["opcional"] == false`.

- [x] **K5.** Verificación real (no solo `mix test`, sin fixture
      maestro-detalle disponible en la suite de tests): script contra
      el catálogo REAL del usuario en dev (`pty_lista_precios`/
      `pty_lista_precios_det`), envuelto en `Repo.transaction/1` con
      `Repo.rollback/1` intencional al final -- `crear_registro/3` creó
      el encabezado (estado inicial, TRN asignado) + 2 renglones reales
      con `encabezado_id` correcto, en el mismo ciclo atómico. Nada
      quedó persistido en dev. Suite completa: 598 tests, mismo
      baseline de 20 fallos preexistentes, cero regresiones nuevas.

## Grupo L — Campos "referencia" en el alta se identifican por descripción (R62-R64, agregado 2026-09-14, revisado el mismo día)

- [x] **L0. Iteración descartada, a pedido explícito**: se implementó y
      verificó primero `resolver_referencias_por_trn/2` (vía
      `meta_schema_transaction_registry`). El usuario pidió revertirlo
      dos veces seguidas ("regresalo como estaba por id interno",
      después "regresalo como estaba por descripción") -- se removió
      TODO el código de la variante TRN (función, cláusula del
      controller, hint de UI, ejemplo), no quedó como código muerto.

- [x] **L1.** `ConsultaEndpoints.resolver_referencias_por_descripcion/2`
      -- cualquier campo real tipo "referencia" presente en un mapa de
      attrs se interpreta como el valor de su
      `props["campos_acompanamiento"]` (mismo campo que ya usa
      `CatalogoGenerico.opciones_referencia/3`), se resuelve buscando
      esa descripción en el catálogo referenciado
      (`is_nil(delete_guid)`) y exigiendo EXACTAMENTE una coincidencia
      -- `{:error, {:referencia_no_encontrada, campo, valor}}` si no
      hay ninguna, `{:error, {:referencia_ambigua, campo, valor}}` si
      hay más de una (el caso real que el propio usuario señaló:
      "puede existir dos veces con la misma descripcion"). Reusada
      tanto para el encabezado como para cada item de `renglones_alta`
      (`resolver_referencias_en_items/3`) -- cualquiera de los dos
      errores en CUALQUIER renglón aborta todo el alta.

- [x] **L2.** Controller -- `mensaje_error_alta/1` traduce las 3
      tuplas nuevas (`:referencia_no_encontrada`, `:referencia_ambigua`,
      `:sin_campo_descripcion`) a mensajes legibles, responde `422`.

- [x] **L3.** UI -- `tipo_hint/1` agrega
      `" (por descripción, debe ser única)"` junto al tipo de cualquier
      campo "referencia" (tabla de Alta, sub-sección Renglones, y
      sección Documentación); `valor_ejemplo_tipo("referencia")` usa un
      placeholder descriptivo en el "Ejemplo de solicitud" en vez de un
      id.

- [x] **L4.** Verificación real (no solo `mix test`, y con el disco
      del usuario reportando 0 bytes libres en el momento -- la suite
      completa no pudo correr por eso, `mix test` ni pudo escribir su
      archivo de resultados; se optó por confiar en esta verificación
      directa y en una corrida acotada de los archivos de test
      afectados, que sí corrió limpia): script contra
      `pty_lista_precios_det_productos` → `pty_productos` en dev
      (`Repo.transaction/1` + `Repo.rollback/1` intencional, 3
      productos creados -- uno único, dos con la MISMA descripción a
      propósito) -- descripción única resuelve al id correcto y crea
      el renglón; descripción compartida por dos productos rechaza
      como `:referencia_ambigua`; descripción inexistente rechaza como
      `:referencia_no_encontrada`. Ningún caso de error insertó nada.
      Corrida acotada de `consulta_endpoint_controller_alta_test.exs` +
      `endpoints_live_test.exs`: 11 tests, 0 fallos.

## Grupo M — Alta: rechazar body sin coincidencias en vez de insertar vacío (R65, agregado 2026-09-17)

- [x] **M1.** `ConsultaEndpoints.crear_registro/3` -- si
      `Map.take(attrs_externos, endpoint.campos_alta)` da `%{}` y
      `campos_alta` no está vacío, corta con
      `{:error, {:body_sin_coincidencias, campos_alta}}` ANTES de tocar
      `CatalogoGenerico.crear/4` -- cubre tanto un body que nunca se
      parseó (Content-Type incorrecto) como uno con nombres de campo
      que no matchean, con el mismo chequeo.

- [x] **M2.** Controller -- `mensaje_error_alta/1` arma un mensaje que
      incluye el Content-Type esperado y la lista completa de
      `campos_alta`, responde `422`.

- [x] **M3.** Hallazgo real que motivó esto: un cliente C#/RestClient
      (Postman) mandaba `Content-Type: text/plain` -- el endpoint
      respondía `201` igual y creaba una fila real con todos los
      campos de negocio en NULL, sin ningún aviso. Verificado el fix
      con ese caso real (dev, `endpoint_historico_127138`,
      `Repo.transaction` + rollback): body vacío y body con nombres
      viejos rechazan con `422`; body con al menos un campo válido
      sigue insertando normal.

- [x] **M4.** Test nuevo en `consulta_endpoint_controller_alta_test.exs`
      -- `POST .../ruta` con body `%{}` y credencial válida → `422`,
      cero filas nuevas en la tabla. Suite completa: 599 tests, mismo
      baseline de 20 fallos preexistentes, cero regresiones nuevas.

## N. Permiso propio "Endpoints" (R66)

- [x] **N1.** `Permissions.@capacidades_sysadmin` -- agregar
      `{"sysadmin_endpoints", "acceso_sysadmin_endpoints", "Endpoints"}`.
- [x] **N2.** Migración `20260917180000_seed_permiso_capacidad_sysadmin_endpoints.exs`
      -- permiso + rol nuevos, migra grants existentes de
      `sysadmin_bc`/`editar`. Aplicada en dev y test.
- [x] **N3.** `EndpointsLive.on_mount` -- `{"sysadmin_bc", "editar"}` →
      `{"sysadmin_endpoints", "leer"}`.
- [x] **N4.** `menu_layout.ex` -- link "Endpoints" gateado por
      `"sysadmin_endpoints"`, agregado a `@recursos_plataforma_bpb`.
- [x] **N5.** Suite completa: 612 tests, mismo baseline de 20 fallos
      preexistentes, cero regresiones nuevas.

## Corrección aparte (no numerada) -- CI roto por drift real en `meta_fixture_cliente` (empresa_id)

Al correr `mix gen.catalogos` localmente (a pedido explícito, para
verificar el catálogo "historico") se encontró que regeneraba
`meta_fixture_cliente.ex` SIN el campo `empresa_id` -- la migración
`20260910120200` que agregó esa columna física lo hizo "sin
meta_schema_detail a propósito" (mismo criterio que branch_id/
sales_unit_id), pero en algún momento posterior alguien agregó
`empresa_id` a mano al `campos:` del `.ex`, violando la invariante real
de `CatalogoGenerador.crear_schema/4` (`campos:` se regenera ENTERO
desde `meta_schema_detail`). Confirmado con `gh run view` que CI venía
fallando por este mismo drift desde ANTES de esta sesión (2 corridas
previas al primer push de hoy ya estaban rojas en el mismo paso).

Mismo bug, mismo patrón, ya documentado una vez antes para
`meta_fixture_cliente_sucursal_id` (ver comentario de la migración
`20260826190000`) -- se repitió porque `empresa_id` no recibió el mismo
tratamiento en su momento.

Corregido con una migración nueva
(`20260917190000_registrar_meta_schema_detail_empresa_id_meta_fixture_cliente.exs`)
que agrega la fila de `meta_schema_detail` faltante -- `campos:` vuelve
a coincidir con la metadata real, el drift desaparece, y el test R55
sigue pasando (ahora por la vía correcta, no por un campo huérfano en
el `.ex`). Aplicada en dev y test, `priv/repo/catalogos/meta_fixture_cliente.meta.json`
actualizado para reflejar la metadata real completa (también le
faltaba `meta_fixture_cliente_sucursal_id`, drift menor preexistente
sin impacto en CI porque el header de este fixture nace de una
migración, no de este archivo). Suite completa tras el fix: 612 tests,
mismo baseline de 20 fallos preexistentes por nombre, cero
regresiones.

## Corrección aparte (no numerada) -- "historico" pasa a ser "pty_h_historico" (catálogo local, fuera de git)

A pedido explícito (2026-09-17, viendo la pantalla "Bisness Context"
junto a pty_ch_areas/pty_ch_empleados/pty_ch_puestos/pty_ch_roles):
"historico" no seguía el estándar `pty_<carpeta>_<nombre>` del resto de
catálogos de esa carpeta. Se renombró la tabla física y sus 38 campos
de negocio (de `historico_<campo>` a `pty_h_historico_<campo>`) más
`meta_schema_header`/`meta_schema_detail`, la Consulta interna del
endpoint (`catalogo_base` + `campos` jsonb), `campos_alta` y
`campos_permitidos` de la credencial -- todo en la base de dev local.

Al confirmar el nombre se encontró un efecto real del `.gitignore`:
todo archivo `pty_*.ex`/`pty_*.json`/migración con "pty_" en el nombre
está EXCLUIDO de git a propósito (son "micro-apps" que arma cada
ambiente por su cuenta vía el BPB, no algo versionado) -- salvo un
puñado de excepciones explícitas (`pty_folio_perfiles`,
`pty_subtipos_transaccion`). "historico" se había creado SIN ese
prefijo justamente para poder vivir en git/CI. Consultado el usuario
(`AskUserQuestion`), eligió **dejarlo fuera de git, como cualquier otro
pty_\***, en vez de agregar una excepción nueva al `.gitignore`.

Consecuencia real: `pty_h_historico.ex`, sus `.meta.json`/`.motor.json`
y la migración del rename (`20260917200000_renombrar_historico_a_pty_h_historico.exs`)
quedan como archivos LOCALES (ignorados), igual que cualquier
migración de un catálogo pty_* -- no viajan a otro ambiente ni a un
checkout limpio. Se retiraron de git los 3 archivos que sí estaban
commiteados bajo el nombre viejo (`historico.ex`,
`priv/repo/catalogos/historico.{meta,motor}.json`). Las migraciones
VIEJAS que crearon la tabla "historico" (2026-09-15 en adelante) siguen
commiteadas sin tocar -- un checkout limpio/CI las sigue corriendo y
termina con una tabla "historico" física, pero sin ningún catálogo de
aplicación detrás (sin header, sin schema Ecto) -- inerte, no la usa
nada. El endpoint publicado sobre este catálogo (`endpoint-historico-127138`,
con sus campos de alta y su credencial) sigue existiendo solo en la
base de dev local, igual que antes de este cambio -- nunca viajó a
ningún lado.

Suite completa tras el rename: 612 tests, mismo baseline de 20 fallos
preexistentes, cero regresiones (ningún test depende de "historico").

## Corrección aparte (no numerada) -- catálogo "Histórico": nombres de campo + tipos reales

Durante las pruebas reales del usuario contra este endpoint se
encontraron y corrigieron, fuera del alcance de R52-R65 pero sobre el
mismo catálogo de ejemplo:

- Los 36 campos de negocio de "historico" se habían creado SIN el
  prefijo `<catalogo>_` que usa todo el resto del sistema (a pedido
  explícito: "cuando creaste el catálogo debieron crearse con el
  nombre del catálogo + el nombre del campo") -- corregido con
  `RENAME COLUMN` real (sin pérdida de datos) + actualización de
  `meta_schema_detail`, el schema Ecto generado, `Consulta.campos`,
  `campos_alta` del endpoint y `campos_permitidos` de su credencial.
- `pzaprev`/`pzaliq` se habían tipado como `:integer`, pero el sistema
  fuente real los manda como decimal (`6.0000`) -- corregido a
  `:decimal` (migración `ALTER COLUMN TYPE`, `meta_schema_detail` y
  schema Ecto actualizados).
- `cargar_todos_por_default` del header estaba en `false` -- la tabla
  no mostraba ninguna fila hasta aplicar un filtro, lo que parecía
  "no hay datos" con datos reales ya cargados. Activado a pedido del
  usuario.
