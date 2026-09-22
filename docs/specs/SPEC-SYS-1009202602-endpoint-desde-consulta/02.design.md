# Design — Crear endpoint a partir de una Consulta

## Resumen del enfoque

Pieza nueva por pieza, reusando patrones ya probados en este repo en
vez de inventar mecanismos propios:

| Necesidad | Patrón que ya existe y se reusa |
|---|---|
| Ruta HTTP resuelta en tiempo real, sin recompilar por cada endpoint | `live "/*ruta", CatalogoLive` (router.ex) — misma idea, comodín compilado una vez |
| Estado borrador/publicado | `MetaSchema.Plantilla`/`PlantillaImportacion` (`campo :estado`, lista fija de valores) |
| Guardar un secreto que solo hay que poder VERIFICAR, nunca releer | `SesionMovil` (hash del refresh token, `SPEC-API-0409202601`) — la API key sigue el mismo patrón, NO el de `MetadataApp.Encriptado` (ver §1, cambiado tras R25) |
| Ejecutar una Consulta con parámetros | `MetaConsultas.ejecutar/6` + `overrides_parametro` — sin cambios |
| Alcance por empresa sin usuario real detrás | Adaptación mínima de `aplicar_where_de_alcance(:empresa, ...)` (catalogo_generico.ex) — ver §4, NO se reusa `Permissions.alcance_tipo_efectivo/2` (necesita un rol de usuario real, acá no hay usuario) |
| Varias credenciales con alcance por campo, por endpoint (R19.1, R42-R46, 2026-09-11) | Tabla hija nueva `ConsultaEndpointCredencial` (§1.2) -- mismo patrón hash que ya usaba el endpoint en la v1, ahora 1:N en vez de 1:1 |
| Millones de registros sin saturar memoria/timeout (R35-R41, 2026-09-11) | Keyset pagination (`WHERE id > cursor`, nunca `OFFSET`) para síncrono + **Oban** (nueva dependencia) para el modo asíncrono — ver §5.2, sin tocar `pagina`/`por_pagina` existente |
| Un POST inserta un registro real, con motor de estados/folio (R54-R58, 2026-09-14) | `CatalogoGenerico.crear/4` (el mismo camino que usa CUALQUIER alta manual desde la UI), con el sentinel `:sistema` (no hay un `Scope` real de un llamador externo) — ver §8, NO se reinventa el motor de estados/folio |

## 1. Modelo de datos — `MetaSchema.ConsultaEndpoint`

Tabla nueva `meta_schema_consulta_endpoint`, un registro por Consulta
como máximo (R8 — índice único en `meta_schema_consulta_id`):

```
id
meta_schema_consulta_id   -- FK, único (1 endpoint por Consulta)
nombre                    -- string
metodo                    -- "get" | "post"
ruta                      -- SOLO el sufijo, ej. "ventas-producto"
                          -- (sin la barra inicial ni el prefijo fijo)
descripcion               -- string, opcional
parametros                -- jsonb: [{"campo": "<clave_campo>", "obligatorio": bool}, ...]
                          -- "campo" es la MISMA clave namespaced que ya
                          -- usa el resto de la Consulta (clave_campo/1)
estado                    -- "borrador" | "publicado" (default "borrador")
empresa_id                -- FK, se fija la primera vez que se guarda
                          -- (la empresa activa de quien lo configuró)
insert_guid / update_guid / delete_guid
timestamps
```

**Cambio 2026-09-11 (R19.1):** `api_key_hash`/`api_key_sufijo` YA NO
viven acá — un endpoint ahora puede tener VARIAS credenciales, así que
esos dos campos se mueven a la tabla nueva `ConsultaEndpointCredencial`
(§1.2). Este registro sigue siendo la config del endpoint en sí
(nombre/método/ruta/parámetros/estado), independiente de cuántas
credenciales tenga.

**Por qué hash y no `MetadataApp.Encriptado` (cambio respecto al primer
borrador de este design):** R25 exige que la key completa se muestre
únicamente al generar/regenerar y nunca más — o sea, la aplicación
nunca necesita volver a LEER la key en texto plano, solo verificar que
lo que llega en un `Authorization: Bearer …` coincide con lo que se
generó. Guardar un secreto que nunca hace falta releer con cifrado
reversible es guardar más riesgo del necesario (una fuga de la DB o de
`Vault` expondría keys vivas). El patrón correcto es el mismo que ya
usa `SesionMovil` para su refresh token: un hash de un solo sentido.
`api_key_sufijo` es la única parte que se guarda en claro, y por diseño
no alcanza para reconstruir la key ni para autenticarse con ella.

Índice único adicional: `(metodo, ruta)` sobre filas sin `delete_guid`
— sin importar el `estado` (R4): dos borradores no pueden reservar la
misma combinación en silencio, para que la colisión se vea al
guardar, no recién al intentar publicar.

`ruta` se valida con un patrón simple (minúsculas, números, guiones,
un solo segmento — ej. `^[a-z0-9-]+$`) — la ruta pública completa
siempre es `"/api/consultas/" <> ruta` (R3). Multi-segmento queda
fuera de esta versión (la ruta comodín del router SÍ lo soportaría
técnicamente, pero la config de v1 se mantiene a un solo segmento por
simplicidad — extensible después sin tocar el router).

`parametros` solo puede referenciar campos que la Consulta ya tiene
marcados `"es_parametro": true` (R5) — se valida al guardar contra
`consulta.campos`, mismo criterio que ya usa `ParametrosCatalogo.
campos_elegibles_*/1` para saber cuáles son elegibles. **R8.1**: esta
misma validación corre en CADA guardado (no solo al crear) — si algún
`campo` de `parametros` ya no aparece como Parámetro vigente de la
Consulta, el changeset falla con un error señalando cuál, y no se
persiste nada (ni siquiera los otros campos del formulario) hasta que
se corrija.

### 1.2 Credenciales — `MetaSchema.ConsultaEndpointCredencial` (R19.1, R42-R46, agregado 2026-09-11)

Tabla nueva, MUCHAS por endpoint (a diferencia de §1, acá no hay
índice único en `meta_schema_consulta_endpoint_id`):

```
id
meta_schema_consulta_endpoint_id  -- FK, MUCHAS por endpoint (R19.1)
nombre                            -- string, ej. "ERP", "Tienda"
api_key_hash                      -- string, SHA-256 en hex -- mismo
                                  -- criterio que ya tenía el endpoint
                                  -- en la v1 (ver nota de §1), ahora acá
api_key_sufijo                    -- string(4), solo para mostrar
                                  -- enmascarada (R25)
campos_permitidos                 -- {:array, :string}: subconjunto de
                                  -- las claves namespaced (clave_campo/1)
                                  -- de los campos VISIBLES del endpoint
                                  -- -- nunca más que eso (R42)
estado                            -- "activa" | "revocada" (default "activa")
insert_guid / update_guid / delete_guid
timestamps
```

Índice único en `api_key_hash` (sin importar `delete_guid`/`estado` —
un hash SHA-256 de 32 bytes aleatorios no debería repetirse nunca,
pero un índice único lo garantiza y además hace la búsqueda por hash
O(1) en vez de recorrer credenciales).

`campos_permitidos` se valida al crear/actualizar contra los campos
VISIBLES de la Consulta del endpoint (`consulta.campos` con
`"visible": true`) — **no** contra los elegibles como Parámetro (R5,
que es un concepto distinto: parámetros son ENTRADA/filtros,
`campos_permitidos` es SALIDA/qué se ve en `"data"`). Un `campo` que ya
no sea visible se comporta igual que R8.1 en §1: bloquea guardar la
credencial hasta corregirla.

`estado: "revocada"` (R23.1) es DISTINTO de borrar la fila —
`delete_guid` queda reservado para una baja real (fuera de esta spec,
no hay UI para "eliminar" una credencial, solo revocarla); una
credencial revocada sigue en la lista (para trazabilidad: "esta key
existió y se cortó tal día") pero `resolver_credencial/2` (§2) nunca la
matchea.

### 1.1 Auditoría — `MetaSchema.ConsultaEndpointLog` (R33-R34)

`MetaAuditoria.registrar/6` no sirve acá (confirmado por inspección):
su forma es para auditar alta/edición/baja de UN registro de negocio
(`catalogo, operacion, guid, registro, datos, contexto`), no para
loguear accesos HTTP. Tabla nueva y chica, sin relación con esa:

```
id
meta_schema_consulta_endpoint_id  -- FK
meta_schema_consulta_endpoint_credencial_id  -- entero, SIN FK viva
                                   -- (agregado 2026-09-11) -- nil si la
                                   -- llamada nunca llegó a resolver una
                                   -- credencial (401 sin match, 404).
                                   -- Guarda el ID, NUNCA el nombre ni la
                                   -- key -- saber "cuál credencial" sin
                                   -- imprimir nada sensible.
fecha_hora                        -- utc_datetime_usec
empresa_id                        -- integer (copiado, no FK viva —
                                   -- el log sobrevive aunque cambie
                                   -- la config del endpoint después)
ip                                 -- string
metodo                             -- "get" | "post"
resultado_http                     -- integer (200, 400, 401, 404, 429, 504...)
duracion_ms                        -- integer
cantidad_registros                 -- integer, nil si no llegó a ejecutar
                                    -- la Consulta (401/400/404)
```

Nunca tiene una columna para la API key ni para los valores de los
parámetros de la llamada (R34 — y por extensión, tampoco se loguean
los VALORES de negocio que viajaron, solo metadata de la llamada). El
`credencial_id` es solo un número interno para poder cruzar "esta fila
de auditoría corresponde a la credencial que hoy se llama ERP" desde
la UI (join en el momento de mostrar, nunca al guardar) — sigue
cumpliendo R34 porque no es la key ni permite reconstruirla.
Se escribe con un `Repo.insert` simple desde el controller (§3, paso
6) — no bloquea la respuesta al cliente: se hace la escritura después
de armar la respuesta, y si el insert de auditoría fallara no debe
tumbar la respuesta HTTP (se loguea el error de auditoría con
`Logger.error/1` y se responde igual — perder una fila de auditoría no
debe convertirse en un 500 para el consumidor externo).

## 2. Módulo de contexto — `MetadataApp.ConsultaEndpoints`

Módulo nuevo (no se agranda `meta_consultas.ex`, ya es grande) con el
CRUD + ciclo de vida:

- `obtener_por_consulta(consulta_id)` / `crear_o_actualizar(consulta, attrs)`
  — corre la validación de R8.1 descrita en §1. Ya NO tocan nada de
  key/credenciales (eso se movió a las funciones de abajo).
- `probar(consulta, scope, overrides_parametro)` — ejecuta
  `MetaConsultas.ejecutar/6` de verdad con esos valores, **usando el
  `current_scope` real de quien está probando** (el admin logueado en
  ese momento — Probar corre DENTRO de la sesión de sysadmin, todavía
  no hay llamada externa ni credencial involucrada, R27/R28). Sin
  cambios por el modelo de credenciales -- Probar sigue viendo TODOS
  los campos visibles, nunca acotado por `campos_permitidos` (eso es
  un recorte que solo aplica a una llamada externa real, R43).
- `publicar(endpoint)` / `despublicar(endpoint)` — togglean `estado`
  del ENDPOINT, sin tocar credenciales (R19.1: publicar/despublicar y
  gestionar credenciales son ortogonales, R24 sigue mandando: sin
  importar cuántas credenciales activas tenga, ninguna funciona si el
  endpoint no está publicado).

**Credenciales (R19.1, R42-R46, agregado 2026-09-11):**

- `crear_credencial(endpoint, consulta, %{"nombre" => ..., "campos_permitidos" => [...]})`
  — valida `campos_permitidos` contra los campos visibles de `consulta`
  (R42), genera la key (`:crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)`),
  calcula `api_key_hash`/`api_key_sufijo` (mismo cálculo que ya usaba
  `publicar/1` en la v1), inserta con `estado: "activa"`. Devuelve
  `{:ok, credencial, key_en_claro}` — la key en claro SOLO en este
  valor de retorno (R25).
- `regenerar_api_key_credencial(credencial)` — mismo cálculo, reemplaza
  hash+sufijo de ESA fila -- las demás credenciales del mismo endpoint
  no se tocan (R23, R23.1). Devuelve `{:ok, credencial, key_en_claro}`.
- `revocar_credencial(credencial)` — `estado: "revocada"` (R23.1) — no
  borra la fila (ver §1.2), sigue apareciendo en la lista.
- `listar_credenciales(endpoint_id)` — todas (activas y revocadas, para
  que la UI las liste igual, R45), ordenadas por `inserted_at`.
- `resolver_credencial(endpoint_id, key_presentada)` — hashea la key
  presentada y busca, indexado por `api_key_hash`, una fila con
  `estado: "activa"`, `is_nil(delete_guid)` y ese
  `meta_schema_consulta_endpoint_id` — `Plug.Crypto.secure_compare/2`
  como verificación final igual que la v1 (defensa en profundidad,
  aunque la búsqueda ya sea por igualdad indexada). `nil` si no matchea
  ninguna (401, R21).
- `invocar(endpoint, consulta, credencial, params_externos, opts_paginacion)`
  — el corazón de la ejecución pública (§3) -- después de construir
  `filas` con `MetaConsultas.ejecutar/6`, filtra cada fila a
  `Map.take(fila, credencial.campos_permitidos)` (R43-R44) ANTES de
  serializar la respuesta.

## 3. Ruteo y controller

**Una sola vez**, en `router.ex`, un scope comodín nuevo (mismo
criterio que `live "/*ruta"`, sección "Mismo motivo que el scope /api
de arriba"):

```elixir
scope "/api/consultas", MetadataAppWeb.Api do
  pipe_through :api  # accepts json -- sin fetch_session/scope de usuario,
                      # este endpoint nunca corre con identidad de Usuario
  get "/*ruta", ConsultaEndpointController, :invocar
  post "/*ruta", ConsultaEndpointController, :invocar
end
```

Va **antes** del scope `/api` genérico existente (mismo motivo que ya
documentan las rutas literales de ahí: más específico primero) — en la
práctica no colisiona igual, porque `/api/:tabla` solo matchea UN
segmento después de `/api` y esto son dos o más, pero se ordena así
por legibilidad y consistencia con el resto del archivo.

`ConsultaEndpointController.invocar/2`:

1. `inicio = System.monotonic_time(:millisecond)`; `ruta = Enum.join(params["ruta"], "/")`,
   `metodo = to_string(conn.method) |> String.downcase()`.
2. `ConsultaEndpoints.obtener_publicado(metodo, ruta)` — `nil` → 404
   JSON (`%{"error" => "Endpoint no encontrado"}`), se loguea igual
   (paso 6) con `resultado_http: 404` pero sin `empresa_id` real (no
   hay endpoint del cual tomarlo — se omite esa fila de auditoría,
   nada que auditar todavía).
3. Extraer el header `Authorization` — DEBE tener la forma exacta
   `"Bearer " <> key` (R20); si el header falta, no trae ese esquema,
   o viene por query string (`?api_key=...`, que ni siquiera se lee),
   es 401 inmediato. Si el esquema es correcto,
   `ConsultaEndpoints.resolver_credencial(endpoint.id, key)` (§2, hash +
   búsqueda indexada + `secure_compare/2` final) — `nil` → 401 JSON,
   **sin ejecutar la Consulta** (R21). A partir de acá el resto del
   flujo tiene la `credencial` resuelta (R19.1), no solo el `endpoint`.
4. Armar `overrides_parametro` desde `conn.body_params` (POST) o
   `conn.query_params` (GET) — SOLO los campos listados en
   `endpoint.parametros`, ignorando cualquier otro que llegue,
   incluido un eventual `empresa_id` (R13: se ignora aunque venga, no
   se rechaza la llamada por traerlo — simplemente nunca se lee para
   nada). Si falta uno marcado `obligatorio` → 400 JSON listando
   cuáles (R10).
5. Paginación (R14-R17): leer `pagina` (default 1, mínimo 1) y
   `por_pagina` (default configurable, ej. 50; tope máximo también
   configurable, ej. 200 — un pedido mayor se recorta al tope, nunca
   se rechaza, R16). `offset = (pagina - 1) * por_pagina`.
6. `ConsultaEndpoints.invocar/5` ejecuta `MetaConsultas.ejecutar/6`
   con esos overrides, el scope forzado a la empresa del endpoint (§4,
   nunca con alcance de un Usuario real), y
   `opciones: [limit: por_pagina, offset: offset]` (ya soportado por
   `ejecutar/6`) — **hallazgo durante la implementación (2026-09-10,
   Grupo C)**: no hace falta un `contar/4` aparte. `ejecutar/6` YA
   calcula `total_filas` con `Repo.aggregate(query, :count)` sobre la
   query filtrada, ANTES de aplicar el `limit`/`offset` de paginación
   — ese valor, tal cual devuelve `ejecutar/6` hoy, es exactamente el
   total que necesita `"meta"` (R17), sin una segunda consulta.
   Ejecuta con un límite de tiempo (R18): se
   pasa `timeout:` (configurable, ej. 10_000 ms) como opción de la
   consulta al `Repo` — si Postgres corta la ejecución por superar ese
   tiempo, se captura el error y se responde 504 JSON
   (`%{"error" => "Tiempo de ejecución excedido"}`) en vez de dejar la
   conexión colgada.
6.1. **Filtro de campos por credencial (R43-R44, agregado 2026-09-11)**:
   antes de armar `"data"`, cada fila se recorta a
   `Map.take(serializar_mapa(fila), credencial.campos_permitidos)` — el
   caller NUNCA puede ampliar ese conjunto (no se lee ningún parámetro
   tipo `?fields=...`, R44 -- ni siquiera se intenta parsear uno).
7. Éxito → `%{"data" => filas, "meta" => %{"pagina" => pagina, "por_pagina" => por_pagina, "total" => total, "total_paginas" => ceil(total / por_pagina)}}`
   (R11, R17) — nunca acepta otro verbo/acción (`post`/`put`/`patch`/
   `delete` sobre ESTA ruta comodín solo están declarados para
   `:invocar`, que solo lee — R12 se cumple estructuralmente, no hace
   falta un chequeo aparte).
8. Al final (éxito o cualquier error a partir del paso 2 con endpoint
   ya resuelto), insertar la fila de auditoría (§1.1) con
   `duracion_ms = System.monotonic_time(:millisecond) - inicio`,
   `ip` tomada de `conn.remote_ip` (o `X-Forwarded-For` si el proxy lo
   setea, mismo criterio que ya use el resto del código si existe un
   helper; si no existe, `conn.remote_ip` a secas), y
   `meta_schema_consulta_endpoint_credencial_id = credencial && credencial.id`
   (nil si nunca se resolvió una) — nunca se incluye la key ni los
   valores de los parámetros (R34).

## 4. Alcance por empresa sin Usuario real

`Permissions.alcance_tipo_efectivo/2` NO sirve acá — resuelve el tipo
de alcance en función de (rol del usuario, catálogo), y acá no hay
usuario. En vez de forzar un `%Scope{}` sintético a través de TODA esa
maquinaria (riesgo real de un caso no contemplado — `:branch`/
`:sales_unit`/`:inventory_location`/`:propio` esperan listas/ids de un
usuario que no existen), se agrega una función nueva y chica,
espejo de `aplicar_where_de_alcance(:empresa, ...)` pero tomando un
`empresa_id` pelado en vez de un `Scope`:

```elixir
# En MetaConsultas, junto a aplicar_alcance_de_datos/4 existente —
# NUEVA función, no una rama más adentro de esa (para que sea
# imposible confundirla con el alcance normal de un usuario logueado).
defp aplicar_alcance_empresa_fijo(query, alias_tabla, empresa_id) do
  # con_columna-equivalent: si la tabla no tiene empresa_id, no-op
  # (mismo criterio permisivo que ya documenta catalogo_generico.ex).
end
```

Esta función se conecta una sola vez, dentro de
`aplicar_alcance_de_datos/4` (nueva cláusula para un cuarto valor de
`scope` posible: `{:empresa_fija, empresa_id}`, junto a las ya
existentes `:sistema`/`nil`/`%Scope{}`) — como el `total_filas` de
`ejecutar/6` se calcula sobre la MISMA `query` ya filtrada por
alcance (ver §3, paso 6), el total reportado en `"meta"` queda
automáticamente acotado a los datos realmente accesibles, sin
duplicar el filtro en un segundo lugar.

Si la Consulta no tiene alcance habilitado en absoluto, o su catálogo
base no tiene columna `empresa_id`, el filtro es un no-op — mismo
comportamiento que tendría cualquier catálogo sin esa columna hoy.
Alcance más granular (sucursal/almacén/unidad de venta/"propio") NO se
soporta para un endpoint publicado (§6, fuera de alcance) — no hay
usuario del cual derivarlo.

## 5. UI — sección dedicada `EndpointsLive` (reescrito 2026-09-14)

**Reemplaza por completo lo que describían las secciones 5 y 5.1
originales** (pestaña "Endpoint API" dentro de `ConsultaEditorLive` +
atajo "+ Endpoint" en `BcListLive`, ambos RETIRADOS) — a pedido
explícito del usuario: *"es que no quiero que dependa de una consulta,
algo como sección endpoint donde pueda elegir el catálogo y crear su
endpoint"*. Ver R47-R51 en requirements.md.

`MetadataAppWeb.Sysadmin.EndpointsLive` es la ÚNICA puerta de entrada
para crear/gestionar un endpoint, con 3 vistas por `@live_action`:

- **`:index`** (`/sysadmin/endpoints`) — tabla de
  `ConsultaEndpoints.listar_todos/0` (nombre, catálogo(s), método+ruta,
  estado, acciones "Configurar"/"Eliminar"). "Eliminar" llama
  `ConsultaEndpoints.eliminar/1`, que borra el `ConsultaEndpoint` Y,
  en cascada (vía `MetaSchemaContext.eliminar_header/1`, FKs
  `on_delete: :delete_all` desde Header → Consulta → ConsultaEndpoint →
  ConsultaEndpointCredencial), el Header oculto y la Consulta interna
  que lo sostenían — mismo criterio que motivó agregar esta acción: el
  incidente real de endpoints duplicados de este mismo día (3 Consultas
  ocultas huérfanas por clicks repetidos del viejo atajo), que antes
  solo se pudo diagnosticar con una consulta SQL directa.
- **`:nuevo`** (`/sysadmin/endpoints/nuevo`) — formulario: **Catálogo
  base** (select, `MetaSchemaContext.listar_catalogos_referenciables/0`
  filtrando los pseudo-catálogos "(sistema)" que esa función agrega —
  un endpoint necesita un Header real detrás) + **Tabla detalle**
  (select opcional, "Ninguna" por default). Al elegir ambos, un
  `phx-change` corre `MetaConsultas.detectar_union/2` en vivo y muestra
  una vista previa (unión detectada / advertencia de fan-out vía
  `maestro_de_detalle/1` / sin relación detectable). Al enviar
  (`crear_endpoint`):
  1. Si hay tabla detalle, `detectar_union/2` otra vez (server-side,
     nunca confía en el estado del cliente) — `:sin_union` aborta TODO
     sin crear nada, con un mensaje pidiendo elegir otra tabla o
     "Ninguna" (R48 -- **a propósito NO ofrece un editor de unión
     manual**, esa es la diferencia deliberada con el armador
     multi-tabla completo de "Nueva consulta" en BC List).
  2. `MetaSchemaContext.crear_header_con_detalles/1` +
     `MetaConsultas.crear/2` (Header oculto, `schema_visible: false`,
     `schema_context_type: 3` -- misma mecánica que tenía el atajo
     retirado) +, si corresponde, `MetaConsultas.agregar_tabla_manual/5`
     con la unión ya resuelta.
  3. **Diferencia deliberada con el flujo viejo (R49):**
     inmediatamente después, `ConsultaEndpoints.crear_o_actualizar/2`
     con valores por defecto (nombre/ruta autogenerados, método GET,
     sin parámetros) — el `ConsultaEndpoint` en `"borrador"` queda
     creado de una, no recién al primer "Guardar". Así el endpoint
     aparece en `:index` desde el primer momento (nunca un Header/
     Consulta ocultos "flotando" sin ningún rastro visible si el admin
     abandona el flujo a mitad de camino) y `eliminar/1` siempre tiene
     algo que borrar.
  4. `push_navigate` a `/sysadmin/endpoints/<nombre>`.
- **`:editar`** (`/sysadmin/endpoints/:nombre`, ruteada por el
  `schema_context_name` del Header oculto -- mismo criterio que ya
  usaba `ConsultaEditorLive`) — panel único de arriba a abajo, sin
  tabs:
  - **Campos** (R50) — tabla equivalente a la sección "Columnas del
    GET" de Get Config (`ConsultaEditorLive`), reutilizando los mismos
    componentes compartidos (`ParametrosCatalogoComponents.celdas_parametro/1`,
    `toggle_es_parametro/1`) y los mismos NOMBRES de evento que esos
    componentes fijan (`cambiar_es_parametro`, `cambiar_acotado`,
    `cambiar_tipo_filtro`, `cambiar_origen`, `cambiar_catalogo_referenciado`,
    `cambiar_defaults_*`) — Visible/Parámetro/Acotado/Tipo de
    filtro/Default, todo editable sin salir de esta pantalla. Recorte
    deliberado de alcance frente a Get Config completo: SIN
    reordenamiento por drag-and-drop, sin "Campos de control" del
    catálogo base ni "Orden de resultados" — ninguno de los dos hace
    falta para que un endpoint funcione, y agregarlos hubiera
    significado duplicar bastante más superficie de
    `ConsultaEditorLive` sin que el usuario lo haya pedido.
  - El resto (Configuración del endpoint, Probar, Publicación,
    Credenciales, Documentación) es el MISMO contenido/lógica que ya
    describían las secciones de abajo (5.2 en adelante y el bloque de
    Credenciales que sigue), migrado tal cual desde el `panel_endpoint_api/1`
    retirado de `ConsultaEditorLive` — sin cambios de comportamiento,
    solo de ubicación.
  - Acción **"Eliminar endpoint"** en el propio panel (mismo
    `ConsultaEndpoints.eliminar/1` que usa `:index`), para no depender
    de volver a la lista.

Contenido original de la pestaña "Endpoint API" (conservado como
referencia de lo que YA describía, ahora vive en `:editar` de
`EndpointsLive` en vez de en `ConsultaEditorLive`):

- Formulario: nombre, método (select GET/POST), ruta (con el prefijo
  fijo mostrado como texto no editable delante del input), descripción.
- Lista de checkboxes: los campos de la Consulta con
  `"es_parametro": true` — tildar uno lo agrega a `parametros`, con un
  toggle "Obligatorio" al lado (mismo patrón visual de chips que ya
  usa `celda_totales/1`). Si al guardar algún campo tildado ya no
  califica (R8.1), el error del changeset se muestra inline junto a
  ese campo, señalando cuál dejó de ser válido.
- Botón **Guardar** (R26) — persiste en estado `"borrador"` si es la
  primera vez.
- Botón **Probar** (R27, visible siempre que esté guardado, publicado
  o no — nunca obligatorio antes de Publicar, R28) — abre un
  mini-formulario con un input por parámetro configurado, ejecuta
  `ConsultaEndpoints.probar/3` y muestra el JSON de respuesta real tal
  cual saldría (incluyendo el bloque `"meta"` de paginación con los
  valores por default).
- Botón **Publicar** / **Despublicar** (R29-R30) — togglea `estado` del
  endpoint, muestra franja con método+ruta completa (botón copiar). Ya
  NO genera ninguna key acá (eso pasó a la sección de Credenciales,
  abajo) — publicar solo abre la puerta, las credenciales son quién
  tiene llave.
- **Sección "Credenciales" (R19.1, R42-R46, agregado 2026-09-11,
  mockup provisto por el usuario)** — reemplaza el bloque único de key
  de la v1. Lista de tarjetas, una por credencial (activa o revocada):
  nombre, punto de estado ("● Activa" verde / "Revocada" gris),
  resumen de alcance ("Solo lectura · N campos" — R12 hace que
  "Lectura" sea siempre el único permiso posible hoy, se muestra fijo
  sin checkbox editable todavía) y 3 acciones: **Ver permisos**
  (expande la lista real de `campos_permitidos`), **Regenerar**,
  **Revocar** (ambas con `data-confirm`, R23/R23.1). Botón
  **"+ Nueva credencial"** al pie abre un formulario: nombre + checkbox
  por cada campo VISIBLE del endpoint ("Campos que puede exponer") —
  al crear, un aviso igual al de la v1 muestra la key COMPLETA una
  única vez (`"copiala ahora, no se va a volver a mostrar"`, R25);
  después, en la lista, solo el sufijo enmascarado.
- **Documentación** (R32): página/sección de solo lectura que arma su
  contenido leyendo el endpoint guardado — método, ruta, esquema de
  autenticación (Bearer, R20), tabla de parámetros (nombre/tipo tomado
  de `consulta.campos`/obligatorio), forma de la paginación (R14-R17),
  **"Ejemplo de solicitud"** (agregado 2026-09-11: `ejemplo_solicitud/3`
  arma un GET con query string real o un POST con body JSON real,
  usando la MISMA convención de nombres externos que interpreta
  `ConsultaEndpoints.construir_overrides/3` — clave tal cual para un
  parámetro simple, `clave_desde`/`clave_hasta` para uno acotado — con
  un valor de ejemplo por tipo: fecha "2026-01-01", entero "1", decimal
  "10.50", lista para `tipo_filtro: "multi"`, texto genérico para el
  resto) y **"Ejemplo de respuesta"** (`documentacion_ejemplo/0`,
  genérico) — **nunca** incluye la key, ni siquiera enmascarada.

## 5.1 Atajo "+ Endpoint" desde BC List (R1.1, agregado 2026-09-11 -- **RETIRADO 2026-09-14**)

**Superado por completo por la sección 5 de arriba.** Esta sección
describía el atajo "+ Endpoint" en `BcListLive` (creaba la Consulta
oculta y aterrizaba en la pestaña "Endpoint API" vía
`?tab=endpoint_api`) — se retiró junto con esa pestaña, reemplazado por
`EndpointsLive` (`:nuevo`), que hace lo mismo (Header oculto +
Consulta interna autogenerados) pero además deja creado el
`ConsultaEndpoint` en borrador de una (R49) y no depende de navegar a
`ConsultaEditorLive` en absoluto. Contenido original conservado abajo
solo como referencia histórica de la mecánica de creación del Header
oculto (sigue siendo la misma):

1. Arma `header_attrs` igual que `guardar_consulta` pero autogenerado:
   `schema_context_name = "endpoint_<catalogo>_<entero único>"`,
   `schema_context_label = "Endpoint — <label>"`,
   `schema_context_nav = "/<schema_context_name>"`,
   `schema_visible = false`.
2. `MetaSchemaContext.crear_header_con_detalles/1` + `MetaConsultas.crear/2`.

`schema_visible: false` es la única diferencia real con una Consulta
"normal": no aparece en el menú de navegación de la app. A diferencia
del atajo viejo, `BcListLive` ya NO muestra estas Consultas ocultas
con ningún botón/atajo propio -- `EndpointsLive` es el único lugar
donde se crean y gestionan.

## 5.2 Grandes volúmenes de resultados (R35-R41, agregado 2026-09-11)

Decisiones ya tomadas por el usuario: cursor se AGREGA sin tocar
`pagina`/`por_pagina` (R37 -- "no modifiques lo que ya existe"), y el
Job asíncrono se construye con **Oban** (nueva dependencia, respaldada
en el mismo Postgres que ya usa la app -- sin infraestructura nueva
que levantar).

### 5.2.1 Paginación por cursor (síncrona, R35-R38)

Nuevo modo de invocación, elegido por la PRESENCIA de un parámetro
`cursor` en la solicitud (ausente → sigue el camino de siempre,
`pagina`/`por_pagina`, sin ningún cambio de comportamiento — R37):

- `cursor` ausente → comportamiento actual, sin tocar (D4/D5 tal cual
  están).
- `cursor` presente (vacío en la primera llamada) + `limite` (default
  configurable, recomendado 5.000 -- R38, tope propio, independiente
  del de `por_pagina`) → en vez de `Repo.aggregate(:count)` +
  `limit/offset`, la query ordena SIEMPRE por `id` del catálogo base
  (asc) y filtra `id > ^cursor_decodificado` (keyset pagination -- por
  qué NO offset: un `OFFSET 500000` obliga a Postgres a recorrer y
  descartar 500.000 filas antes de devolver la página 500.001, cada
  vez más lento cuantas más páginas se piden; `WHERE id > cursor LIMIT N`
  siempre usa el índice de la PK sin importar en qué "página" se está,
  R41). Sin `Repo.aggregate(:count)` tampoco (R35: contar
  potencialmente millones de filas en cada lote sería el mismo
  problema que se quiere evitar) — la respuesta de este modo NO trae
  `"total"`/`"total_paginas"` en `"meta"`, solo
  `"cursor_siguiente"` (el `id` de la última fila del lote, `nil` si
  ya no hay más) y `"tiene_mas"` (boolean).
- El `cursor` que viaja en la respuesta/solicitud es el `id` crudo
  codificado en Base64 (`Base.url_encode64/1`) -- no expone
  directamente un id secuencial de la tabla en texto plano en la URL,
  aunque tampoco pretende ser un secreto (es solo una posición, no una
  credencial).
- Ruta y auth exactamente iguales (mismo controller, mismo
  `ConsultaEndpoints.resolver_credencial/2`, mismo filtro de campos
  por credencial, §5) — el modo cursor es una FORMA distinta de armar
  `opciones` para `MetaConsultas.ejecutar/6`, no un endpoint nuevo.
- `MetaConsultas.ejecutar/6` gana soporte a `opciones[:despues_de_id]`
  (en vez de `offset:`) -- nueva cláusula que se agrega, `limit:`/
  `offset:`/`timeout:` existentes no se tocan.

### 5.2.2 Ejecución asíncrona vía Job (R39-R41)

- Dependencia nueva: `Oban` (+ su migración estándar,
  `Oban.Migration.up/1`, tablas `oban_jobs`/`oban_peers` propias de la
  librería -- no se reinventa una tabla de jobs a mano).
- Worker `MetadataApp.Workers.ConsultaEndpointJob` (`use Oban.Worker`):
  recibe `job_id`+`overrides_parametro` como args del job (`job_id`
  resuelve `endpoint`/`credencial` desde `ConsultaEndpointJob`).
  **Decisión durante la implementación (2026-09-11)**: en vez de
  `Repo.stream/2` (necesitaría exponer la query interna de
  `MetaConsultas` fuera del módulo), reusa el MISMO mecanismo de
  paginación por cursor de §5.2.1 en un loop -- llama
  `MetaConsultas.ejecutar/6` repetidas veces con
  `despues_de_id`/`limit: 5_000`, escribiendo cada lote al NDJSON antes
  de pedir el siguiente. Cumple R41 igual (nunca más de un lote en
  memoria a la vez) reusando código ya probado del modo síncrono, en
  vez de duplicar la lógica de armar la query con una API nueva.
- Resultado grande → se escribe incremental a un archivo NDJSON (una
  fila JSON por línea) en disco local, vía `MetadataApp.ArtefactosJob`
  (módulo nuevo, chico) -- NO en una columna de la base (un `jsonb` con
  millones de filas sería el mismo problema de memoria al leerlo
  después). El path del archivo se guarda en una tabla nueva
  `meta_schema_consulta_endpoint_job` (id, endpoint_id, credencial_id,
  estado -- "pendiente"|"en_curso"|"completado"|"fallido", oban_job_id,
  archivo_resultado, cantidad_registros, error, timestamps).
- Dos rutas nuevas bajo el mismo prefijo (`/api/consultas/<ruta>/jobs`,
  mismo auth por credencial que la síncrona):
  - `POST .../jobs` -- encola el Oban.Job, responde
    `202 Accepted` + `{"job_id":, "estado": "pendiente"}` de inmediato
    (nunca espera a que termine).
  - `GET .../jobs/:job_id` -- devuelve estado; si `"completado"`,
    sirve el archivo NDJSON armado (streaming, `Plug.Conn.send_file/5`
    -- otra vez, nunca carga el archivo entero en memoria para
    responderlo).
- `campos_permitidos` de la credencial se aplica ACÁ TAMBIÉN (R43) --
  el worker filtra cada fila antes de escribirla al NDJSON, nunca
  después.

## 6. Rate limiting (R30 del requirements) — solo contrato, sin implementar

A pedido explícito ("solo documentar, implementar después"): esta
versión NO agrega ningún mecanismo de conteo/ventana. El contrato que
cualquier implementación futura debe respetar, para no romper a los
consumidores que se integren contra esta v1:

- Limita por API key (no por IP — varias integraciones podrían salir
  de la misma IP corporativa).
- Al exceder el límite, responde `429 Too Many Requests` con un cuerpo
  JSON de error consistente con los demás (`%{"error" => "..."}"`).
- No participa del cálculo de `"meta"` ni de la auditoría (§1.1) más
  allá de que un 429 también se loguearía como cualquier otro
  `resultado_http` — el contador en sí no vive en la tabla de
  auditoría (sería otra estructura, ej. algo en memoria o Redis según
  lo que exista cuando se implemente).
- No se reserva ningún campo en el modelo de datos (§1) para esto
  todavía — cuando se implemente, probablemente ni siquiera haga falta
  tocar `meta_schema_consulta_endpoint`.

## 7. Fuera de alcance (explícito)

- La ruta implícita `GET /api/<nombre_consulta>` — no se toca (a
  pedido explícito).
- Alcance por sucursal/almacén/unidad de venta/"propio" en un endpoint
  publicado — solo empresa (§4). Decisión explícita (2026-09-10): si la
  Consulta necesita algo más granular, el endpoint se publica IGUAL,
  sin ese filtro extra — nunca se bloquea la publicación por esto,
  mismo criterio permisivo que el resto de esta pieza. Queda
  documentado como limitación conocida (visible en la pantalla de
  configuración cuando aplique), no como un bloqueo.
- Rutas de más de un segmento bajo el prefijo — el modelo de datos ya
  lo permitiría a nivel de router, la UI de configuración no lo ofrece
  todavía.
- Implementación real de rate-limiting (§6 — solo contrato documentado
  en esta versión).
- Versionado de un endpoint ya publicado (cambiar su contrato sin
  romper consumidores existentes) — cada guardado simplemente
  actualiza la única configuración viva.
- **"Nivel 4" de la evolución de seguridad** (agregado 2026-09-11, a
  pedido explícito del propio usuario): filtros permitidos y rate
  limit propios POR CREDENCIAL quedan fuera — hoy el alcance por
  empresa (R22) y el timeout (R18) son iguales para TODAS las
  credenciales de un mismo endpoint.
- **Retención/limpieza de archivos NDJSON de Jobs completados**
  (agregado 2026-09-11) — esta versión no borra archivos viejos ni
  limita cuántos Jobs puede tener un endpoint corriendo a la vez; un
  mecanismo de limpieza/cuota queda para una iteración aparte.
- **UI dentro de `ConsultaEditorLive` para disparar/ver Jobs** — el
  mecanismo asíncrono (§5.2.2) se consume por API (`POST .../jobs`,
  `GET .../jobs/:id`), no hay una pantalla de sysadmin para lanzarlo a
  mano ni para ver su progreso; eso también queda para después.
- **Permiso de escritura por credencial** (agregado 2026-09-14, ver
  R54-R58) — cualquier credencial activa del endpoint puede usar el
  alta si está habilitada, no hay un permiso "puede escribir" propio
  todavía (decisión documentada, no confirmada explícitamente).

## 8. Alta de registros vía POST (R54-R58, agregado 2026-09-14)

**Campos nuevos en `ConsultaEndpoint`** (migración
`20260914130000_agregar_alta_a_consulta_endpoint.exs`):
`permite_alta` (boolean, default false) y `campos_alta` ({:array,
:string}, whitelist de campos REALES del catálogo base — no de la
Consulta, que usa claves namespaced `catalogo__campo` para un
propósito distinto). El changeset valida `campos_alta` contra
`MetaSchemaContext.listar_detalles(consulta.catalogo_base)`, mismo
criterio que `validar_parametros_vigentes/2` ya usaba para
`parametros`.

**Dispatch en el controller** (`ConsultaEndpointController.ejecutar/5`):
si `endpoint.metodo == "post" and endpoint.permite_alta`, el body
NUNCA se interpreta como filtros — va directo a
`ejecutar_alta/5`, que llama `ConsultaEndpoints.crear_registro/3`.
Los dos modos (consulta vía body / alta) son mutuamente excluyentes
por endpoint, decisión explícita — no hay forma de que un mismo POST
sirva para las dos cosas.

**`ConsultaEndpoints.crear_registro/3`**:
1. Resuelve el módulo Ecto real del catálogo base vía
   `MetaSchemaContext.modulo_por_nombre/1` (mismo helper que ya usan
   `PlantillaConstructorLive`/`BcMotorLive` para "registro de
   muestra").
2. Recorta `attrs_externos` a `endpoint.campos_alta`
   (`Map.take/2`) — CUALQUIER campo que el body mande pero no esté
   habilitado se descarta antes de llegar a ningún changeset (R55).
3. Estampa `"empresa_id" => endpoint.empresa_id` SIEMPRE que la tabla
   tenga esa columna, pisando cualquier valor que el body externo
   hubiera mandado (R57) — es la única fuente de la empresa correcta,
   nunca algo que el caller pueda controlar.
4. Llama `CatalogoGenerico.crear(modulo, :sistema, attrs)` — el MISMO
   camino que un alta manual desde la UI: motor de estados
   (`MetaStateEngine.transicion_alta/1` o `estado_inicial/1`), folio/
   TRN si el catálogo es transaccional (`IdentificadoresTransaccionales.asignar/4`,
   ya integrado dentro de `crear/4`), validaciones de campo (R56). El
   sentinel `:sistema` (ya existente en `CatalogoGenerico`, usado hoy
   por `Renglones.crear_todos/3` y herramientas de Constructor) es
   necesario porque no hay un `Scope` real de usuario logueado detrás
   de un llamador externo — por eso el estampado de `empresa_id` del
   paso 3 es manual: `:sistema` bypasea `preparar_attrs_alcance/4` por
   completo, así que ningún auto-estampado de empresa/jerarquía pasa
   solo.
5. Un catálogo de negocio sin NINGÚN estado configurado ya rechaza con
   `{:error, :motor_no_configurado}` (decisión preexistente de
   `crear_simple_o_rechazar/4`, 2026-09-10) — se propaga tal cual, R56
   ("rechazar con un error claro, nunca insertar en silencio") sale
   gratis de una regla que ya existía.

**Respuesta HTTP**: `201 {"data": {"id": <id>}}` en éxito; `422` con
`{"error": "<mensaje>"}` en fallo — `mensaje_error_alta/1` traduce un
`%Ecto.Changeset{}` (errores de validación real) o hace `inspect/1`
de cualquier otro motivo (`:motor_no_configurado`, etc.).

**UI en `EndpointsLive` `:editar`** — nueva tarjeta "Alta de registros
(el POST inserta filas)", visible solo si `@endpoint.metodo == "post"`:
toggle `permite_alta` + tabla de checkboxes de
`MetaSchemaContext.listar_detalles(consulta.catalogo_base)` (campo/
tipo/obligatorio del catálogo, no de la Consulta). La sección
Documentación bifurca por completo en modo alta: en vez de la lista de
parámetros de filtro, muestra los `campos_alta` habilitados con su
tipo/obligatorio, y el "Ejemplo de solicitud"/"Ejemplo de respuesta"
(`ejemplo_alta/3`, `documentacion_ejemplo_alta/0`) refleja el body de
inserción real y la respuesta `201`, no la forma de una consulta.

**Bug real encontrado y corregido (2026-09-14):** el "obligatorio en
el catálogo" de la tabla de arriba leía `props["obligatorio"]` — esa
clave no existe en un catálogo real generado desde BC List, que usa
`"opcional"` (invertido; `"obligatorio"` solo existe como concepto en
`dependencias_default`, algo distinto). Corregido a
`props["opcional"] == false` en `campos_reales_alta/1` — sin la
corrección, el badge siempre mostraba "No" sin importar el contrato
real del campo.

## 9. Renglones de detalle en el alta (R59-R61, agregado 2026-09-14)

Mismo día que R54-R58, a pedido explícito inmediato: *"falta las
filas del detalle"* -- si `catalogo_base` es un catálogo MAESTRO
(`schema_encabezado_id` de alguno de sus catálogos detalle apunta a
él), el alta puede crear también los renglones iniciales, reusando el
mecanismo `opciones[:renglones]` de `CatalogoGenerico.crear/4` que ya
usan `catalogo_controller.ex`/`ficha_live.ex`/`meta_importacion_datos.ex`
para exactamente lo mismo -- ningún mecanismo nuevo, solo un caller
más.

**Campo nuevo**: `renglones_alta` ({:array, :map}, default []) en
`ConsultaEndpoint` -- `[%{"catalogo" => "<catalogo_detalle>", "campos" => [...]}, ...]`.
Changeset valida cada entrada contra
`MetaSchemaContext.listar_catalogos_detalle(header_maestro_id)` (el
catálogo debe ser detalle REAL de `catalogo_base`) y contra
`listar_detalles/1` de ese catálogo detalle (los campos deben ser
reales de ESE catálogo, R59).

**`ConsultaEndpoints.crear_registro/3`** arma `opciones[:renglones]`
(función privada `renglones_spec_desde_externos/2`): por cada entrada
de `renglones_alta`, busca en `attrs_externos` una lista bajo la clave
del catálogo detalle (`Map.get(attrs_externos, catalogo)`); si es una
lista, recorta cada item a los campos whitelisteados
(`Map.take(item, campos)`) y arma
`%{"<catalogo_detalle>" => [item_recortado, ...]}`; si el body no
mandó esa clave, se omite en silencio (mismo criterio que
`Renglones.crear_todos/3` con `%{}` — renglones opcionales por
defecto). `encabezado_id` lo estampa `Renglones.crear_cada_renglon/3`
solo, NUNCA algo que pueda mandar el body (R61).

**UI**: dentro de la misma tarjeta "Alta de registros", una sub-sección
"Renglones" (solo si `MetaSchemaContext.listar_catalogos_detalle/1`
devuelve algo para `catalogo_base`) — un bloque por catálogo detalle
con checkboxes de sus campos reales, mismo patrón visual que la
whitelist del maestro. La Documentación agrega, cuando corresponde, un
bloque "Renglones · &lt;etiqueta&gt;" con los campos habilitados, y el
"Ejemplo de solicitud" incluye la clave del catálogo detalle con un
array de un item de ejemplo.

**Verificado con datos reales** (2026-09-14, `pty_lista_precios` /
`pty_lista_precios_det` en dev, dentro de una transacción con
`Repo.rollback/1` intencional al final -- nada quedó persistido):
`crear_registro/3` creó el encabezado (`estado_id` del estado inicial,
TRN asignado) + 2 renglones reales con `encabezado_id` correcto, en el
mismo alta atómico.

## 10. Campos "referencia" en el alta se identifican por descripción (R62-R64, agregado 2026-09-14 -- revisado el mismo día)

**Se probó e implementó resolver por TRN primero** (vía
`meta_schema_transaction_registry`, mismo mecanismo que
`BuscadorTrnLive`), verificado con datos reales, y luego el usuario
pidió explícitamente revertirlo -- primero a "id interno" (`"regresalo
como estaba por id interno"`), después a descripción (`"regresalo como
estaba por descripción"`). Este `## 10` describe la versión FINAL,
que identifica por descripción con detección de ambigüedad -- no
queda ningún rastro de código de la variante TRN (se removió por
completo, no solo se dejó de usar).

`ConsultaEndpoints.resolver_referencias_por_descripcion/2` (pública,
reusada tanto para `attrs` del encabezado como para cada item de
`renglones_alta` vía `resolver_referencias_en_items/3`): por cada
campo REAL cuyo `schema_context_properties["tipo"]` sea `"referencia"`
y que esté presente en el mapa recibido, toma su
`props["campos_acompanamiento"]` (el MISMO campo que ya usa
`CatalogoGenerico.opciones_referencia/3` para la etiqueta de un
selector de referencia -- no una noción nueva) e interpreta el valor
recibido como ese campo de descripción, nunca como un id. Resuelve con
`WHERE <campo_descripcion> == ^valor AND is_nil(delete_guid)` sobre el
catálogo referenciado y exige EXACTAMENTE una fila:

- 0 coincidencias → `{:error, {:referencia_no_encontrada, campo, valor}}`.
- 1 coincidencia → `{:ok, id}`.
- 2+ coincidencias → `{:error, {:referencia_ambigua, campo, valor}}` --
  el caso real que el propio usuario señaló ("puede existir dos veces
  con la misma descripcion"), nunca se elige una al azar.

`crear_registro/3` aborta TODO (encabezado + renglones) ante
cualquiera de los dos errores, sin llegar a tocar
`CatalogoGenerico.crear/4`. El controller traduce ambas tuplas a un
mensaje legible (`mensaje_error_alta/1`, 3 cláusulas nuevas incluyendo
`:sin_campo_descripcion` si el campo real no tiene
`campos_acompanamiento` configurado) y responde `422`. La UI muestra
`" (por descripción, debe ser única)"` junto al tipo de cualquier campo
"referencia" (`tipo_hint/1`, tabla de configuración de Alta/Renglones y
sección Documentación) y el "Ejemplo de solicitud" usa un placeholder
descriptivo en vez de un id (`valor_ejemplo_tipo("referencia")`).

**Limitación conocida, no resuelta en esta versión:** si un campo
"referencia" no tiene `campos_acompanamiento` configurado, no hay
forma de identificarlo por descripción -- el alta para ese campo
específico siempre rechaza con `:sin_campo_descripcion`; admitir un
id interno como fallback en ese caso queda fuera de esta versión.

Verificado con datos reales (2026-09-14, `pty_lista_precios_det_productos`
→ `pty_productos` en dev, transacción con rollback intencional, 3
productos creados -- uno con descripción única, dos con la MISMA
descripción a propósito): descripción única → resuelve al id correcto
y crea el renglón; descripción compartida por los dos productos →
`{:error, {:referencia_ambigua, ...}}`; descripción inexistente →
`{:error, {:referencia_no_encontrada, ...}}`. Ninguno de los dos casos
de error insertó nada.

## 11. Alta: rechazar body sin coincidencias en vez de insertar vacío (R65, agregado 2026-09-17)

Hallazgo real usando el endpoint de "historico" en producción de
pruebas: un cliente C#/RestClient (generado por Postman) mandaba
`request.AddParameter("text/plain", body, ParameterType.RequestBody)`
-- el pipeline `:api_consulta_endpoint` (`Plug.Parsers`, `pass:
["*/*"]`) nunca intenta el parser `:json` sobre un body con
`Content-Type: text/plain`, así que `conn.params` llegaba al
controller sin ninguna clave del body (solo el `"ruta"` del path). El
alta igual respondía `201` (todo campo es opcional) y creaba una fila
real con TODOS los campos de negocio en NULL -- exactamente el
síntoma que reportó el usuario ("no me salen datos"), sin ningún error
visible.

`ConsultaEndpoints.crear_registro/3` ahora corta ANTES de llegar a
`CatalogoGenerico.crear/4`: calcula `Map.take(attrs_externos,
endpoint.campos_alta)` y, si el resultado es `%{}` mientras
`campos_alta` sí tiene algo configurado, devuelve
`{:error, {:body_sin_coincidencias, campos_alta}}` sin insertar nada.
Este único chequeo cubre los dos escenarios reales (Content-Type
incorrecto → `attrs_externos` llega vacío; nombres de campo viejos/mal
escritos → `attrs_externos` no vacío pero ninguna clave matchea) con
la misma lógica. El controller (`mensaje_error_alta/1`) arma un
mensaje que incluye Content-Type esperado + la lista completa de
`campos_alta`, para que el caller pueda comparar de una contra lo que
mandó, y responde `422`.

Verificado con datos reales (dev, `endpoint_historico_127138`, vía
`Repo.transaction` + rollback): body vacío → rechaza;
body con los nombres de campo viejos (pre-R54-R61) → rechaza; body
con al menos un campo válido → sigue insertando normal. Test HTTP real
(`consulta_endpoint_controller_alta_test.exs`): `POST .../ruta` con
body `%{}` y credencial válida → `422`, cero filas nuevas en la
tabla.

## 12. Permiso propio para "Endpoints" (R66)

`Permissions.@capacidades_sysadmin` (fuente única para la pestaña
"Sysadmin" de `UsuariosEmpresaLive`) es una lista fija en código de
`{recurso, rol_nombre, etiqueta}` -- cada capacidad es un permiso
`{recurso, "leer"}` + un rol de sistema dedicado que se linkea a ESE
único permiso. "Endpoints" se agrega como una entrada más:
`{"sysadmin_endpoints", "acceso_sysadmin_endpoints", "Endpoints"}`.

`EndpointsLive` cambia su `on_mount` de
`{"sysadmin_bc", "editar"}` a `{"sysadmin_endpoints", "leer"}` --
mismo criterio que ya usan Tepache/Credenciales/Ambientes/Panel
Control (una pantalla, un recurso, acción `"leer"` alcanza porque no
hay una acción más fina definida para estas pantallas de Sysadmin).
El link "Endpoints" del menú (`menu_layout.ex`) pasa a depender de
`"sysadmin_endpoints" in @opciones_plataforma` en vez de
`"sysadmin_bc"`, y se agrega a `@recursos_plataforma_bpb` (sigue
exigiendo `bpb_habilitado`, igual que antes).

Migración `20260917180000`: siembra el permiso + rol nuevos, y migra
automáticamente el acceso de cualquier rol que ya tuviera
`sysadmin_bc`/`editar` concedido (mismo patrón de compatibilidad hacia
atrás que usó `20260816014352` al separar Tepache) -- nadie pierde
acceso a Endpoints que ya tenía por tener acceso a Business Process
Builder.

## 13. Publicar Endpoints entre ambientes (R67-R71, agregado 2026-09-17)

### Decisión: reusar el pipeline de `mix motor.publicar`, no crear uno nuevo

Un `ConsultaEndpoint` es metadata pura -- una fila de tabla, sin módulo
Ecto compilado ni migración propia -- igual que la Consulta de la que
depende (`schema_context_type: 3`, que "no tiene módulo Ecto propio",
ver comentario de `CatalogoController.index/2`). El pipeline de
catálogos YA exporta/importa metadata pura por este mismo camino:
`mix meta.export` escribe `<catalogo>.meta.json`, ese archivo viaja
adentro del bundle de `mix motor.publicar`, y
`MetadataApp.Release.import_meta/0` lo lee de vuelta en el release
target, después de `migrate/0`. Un Endpoint es un caso más de lo
mismo -- no justifica un comando propio, ni un workflow de GitHub
Actions aparte, ni tocar `bpb_habilitado` (la pantalla
`Sysadmin.EndpointsLive` sigue sin existir en destino, y no hace
falta que exista: nunca es ella la que escribe la fila ahí).

**Cinco correcciones sobre el borrador anterior -- las primeras tres
encontradas leyendo el código real antes de implementar, la cuarta y
la quinta recién en la prueba end-to-end contra `unstable` (regla del
proyecto, nunca asumir):**

- **`mix meta.export`/`importar_meta` (mecanismo genérico preexistente,
  no escrito para esta spec) solo maneja Header+Detail -- NUNCA toca
  `meta_schema_consulta`.** Hallazgo real, log de `bc-deploy.yml`: el
  header de un Endpoint llegaba bien (`+ ...: creado`) pero
  `MetaConsultas.obtener_por_catalogo/1` seguía devolviendo `nil` en
  destino, y el Endpoint nunca se creaba (`- ...: consulta no
  encontrada`). Nadie había publicado una Consulta antes de esta spec,
  así que este hueco de la plataforma nunca se había notado.
  Corregido DENTRO del mecanismo de Endpoints (sin tocar el
  `meta.export`/`.meta.json` genérico, que no lo necesita para nada
  más hoy): `exportar_endpoint/2` suma
  `catalogo_base`/`campos`/`joins`/`orden_por` de la Consulta al
  `.endpoint.json`, y `importar_endpoint/1` crea o actualiza esa fila
  a mano (`asegurar_consulta/2`) ANTES de resolver la Empresa y crear
  el `ConsultaEndpoint`.
- **`asegurar_consulta/2` (recién agregada arriba) se olvidó de
  `insert_guid`.** Hallazgo real, log de `bc-deploy.yml` un deploy
  después del anterior: `ERROR 23502 (not_null_violation) null value
  in column "insert_guid"` -- `Consulta.changeset/2` no castea
  `insert_guid`/`update_guid`/`delete_guid` (no están en su lista de
  campos permitidos), hay que setearlos a mano con
  `Ecto.Changeset.change/2` después del changeset, mismo patrón que ya
  usa CUALQUIER otro `crear`/`actualizar` de este proyecto
  (`ConsultaEndpoints.crear/2`, `MetaSchemaContext.
  crear_header_con_detalles/1`, etc.). Corregido: `insert_guid` al
  crear, `update_guid` al actualizar.

- `ConsultaEndpoints.eliminar/1` NO hace soft-delete: es un
  `Repo.delete` real sobre el Header oculto que sostiene la Consulta
  interna, con `on_delete: :delete_all` cascadeando a la Consulta, el
  Endpoint y sus credenciales. `delete_guid` en `ConsultaEndpoint`
  nunca se setea en la práctica (solo se LEE con `is_nil`, ver
  `obtener_publicado/2`/`listar_todos/0`) -- no hay ninguna fila de la
  que "exportar el borrado" después de eliminar. El plan original de
  R71 (republicar y que el `delete_guid` viaje solo) no aplica acá.
- `ConsultaEndpoint.empresa_id` es un id crudo de `Empresa`, no
  portable entre bases -- cada ambiente tiene sus propias filas de
  Empresa con sus propios ids. Exportarlo tal cual e insertarlo en
  otro ambiente apuntaría a la empresa equivocada (o a ninguna).
  Mismo problema que ya resolvió `MetaSchemaContext.exportar_header/2`
  para el maestro de un catálogo detalle -- exporta
  `schema_encabezado_catalogo` (el NOMBRE), nunca el id crudo. Acá se
  aplica el mismo criterio: se exporta `empresa_nombre`, se resuelve
  contra el destino al importar.
- El tombstone de despublicar (punto 5) NO puede viajar en un release
  de GitHub separado con el mismo tag `bc-<consulta>` que ya usa el
  bundle NORMAL de esa Consulta -- `persistir_bundle/2` reemplaza
  (`--clobber`) el asset entero de ese tag, y `ci.yml` restaura
  SIEMPRE el último asset de cada `bc-*` en todo deploy futuro. Si el
  tombstone reemplazara ese asset con SOLO el archivo de borrado, el
  próximo deploy dejaría de recibir el `.ex`/migraciones/`.meta.json`
  de la Consulta -- "despublicar el Endpoint" terminaría
  "despublicando la Consulta entera" por accidente. Corregido: el
  tombstone viaja DENTRO del mismo bundle completo de siempre (mismo
  tag, sin reemplazar nada de lo demás) -- ver punto 5.

### Piezas nuevas

1. **Export** -- `mix endpoint.export` (tarea nueva, mismo patrón que
   `meta.export`): por cada Consulta que tenga un `ConsultaEndpoint`
   VIVO, escribe `priv/repo/catalogos/<consulta>.endpoint.json` con
   `catalogo` (el nombre de la Consulta -- mismo motivo que ya usan
   `.motor.json`/`.plantillas.json`: `leer_json/2` descarta el nombre
   de archivo, así que el nombre tiene que viajar DENTRO del JSON),
   nombre/método/ruta/parámetros/campos_alta/renglones_alta/estado y
   **`empresa_nombre`** (resuelto desde `empresa_id` vía `Repo.get!
   (Empresa, ...).nombre`, nunca el id crudo). Nunca serializa nada de
   `ConsultaEndpointCredencial` (R69) -- esa tabla ni se toca acá.
   Mismo criterio que `meta.export`: sincroniza el directorio, borra
   el `.endpoint.json` huérfano de una Consulta que ya no tiene
   Endpoint -- EXCEPTO si el contenido actual del archivo ya es el
   tombstone del punto 5 (`"eliminado": true`): ESE nunca se borra ni
   se regenera acá, es responsabilidad exclusiva de `mix
   endpoint.despublicar`.

2. **Import** -- `MetaImportExport.importar_endpoint/1`, llamada desde
   `MetadataApp.Release.import_meta/0` junto a `importar_meta/1`,
   `importar_motor/1` e `importar_plantillas/1` (en ESE orden --
   necesita que el header de la Consulta ya exista). Por cada
   `<consulta>.endpoint.json` encontrado: resuelve el header por
   nombre, resuelve `empresa_nombre` contra la tabla `Empresa` DEL
   DESTINO -- **corregido en vivo** (2026-09-17, "DemoCore Sa. de C.V"
   en local vs. "Unstable" en unstable: el import fallaba en silencio,
   0 filas, sin error visible en la UI): exigir el mismo NOMBRE es poco
   realista, unstable/cualquier cliente real suelen tener una sola
   Empresa. Si no hay coincidencia por nombre pero el destino tiene
   EXACTAMENTE una Empresa viva, se usa esa como default. 0 o 2+ sin
   nombre exacto sigue siendo error explícito (nunca una adivinanza) y
   ese archivo se salta -- mismo criterio tolerante que
   `importar_contexto_tolerante/1`, un endpoint roto no tumba el resto
   del import. Con la Empresa resuelta, hace `ConsultaEndpoints.crear_o_actualizar/2` (ya
   existe, B1) -- upsert por `meta_schema_consulta_id` (único, R8),
   reemplaza la fila completa (R68).

3. **Bundle** -- `MetaPublicador.rutas_de/1` suma
   `priv/repo/catalogos/#{catalogo}.endpoint.json` a la lista de
   archivos, con el mismo filtro `File.exists?/1` que ya usan
   `meta`/`motor`/`plantillas` -- se incluye solo si existe, cero
   cambio de comportamiento para un catálogo sin endpoint.

4. **CLI publicar** -- `Mix.Tasks.Motor.Publicar.publicar/2` suma
   `Mix.Task.rerun("endpoint.export")` a la cadena de exports que ya
   corre antes de armar el bundle.

5. **Despublicar (corregido TRES veces sobre el borrador original,
   probado en vivo 2026-09-17)** -- `mix endpoint.despublicar
   --sistema=<sistema> <consulta>` (tarea nueva). Exige que el Endpoint
   YA esté borrado local (`ConsultaEndpoints.obtener_por_consulta/1`
   == `nil` para esa Consulta) -- si todavía existe, error explícito.
   Escribe a mano el tombstone `priv/repo/catalogos/<consulta>.endpoint.json`
   = `{"catalogo": "<consulta>", "eliminado": true}`, y arma/sube/dispara
   el deploy llamando DIRECTO a `MetaPublicador.armar_bundle/1` +
   `persistir_bundle/2` + `disparar_deploy/3` -- el MISMO patrón que ya
   usa `mix motor.despublicar` para un catálogo real. **Se descartó
   delegar en `mix motor.publicar`** (segundo borrador): ese task
   arranca con `MetaPublicador.validar/1`, que exige que el header
   EXISTA -- imposible acá, porque `ConsultaEndpoints.eliminar/1` ya lo
   borró en cascada (Header + Consulta + Endpoint + credenciales, ver
   arriba). Reemplazar el release `bc-<consulta>` entero (en vez de
   preservarlo, como decía el primer borrador) es seguro en este caso
   puntual: la Consulta detrás de un Endpoint de esta sección SIEMPRE
   es interna y descartable junto con él (nunca una Consulta de
   usuario reusada, ver R47-51: "no quiero que dependa de una
   consulta") -- no hay nada más bajo ese tag que preservar.
   `importar_endpoint/1` (punto 2), al ver `"eliminado" => true` en vez
   de la forma normal, hace `Repo.delete` real del `ConsultaEndpoint`
   del destino si existe (nunca error si ya no existía -- despublicar
   dos veces es idempotente).

### Cómo quedan resueltos R67-R71

- **R67** -- `mix motor.publicar --sistema=<sistema> <consulta>` (el
  MISMO comando que ya existe para cualquier catálogo) alcanza: la
  fila llega vía `import_meta`, sin que `/sysadmin/endpoints` tenga
  que existir en destino.
- **R68** -- `crear_o_actualizar/2` (upsert por
  `meta_schema_consulta_id`), nunca un insert ciego que duplique.
- **R69** -- satisfecho por construcción: el export nunca lee ni
  escribe nada de `ConsultaEndpointCredencial`.
- **R70** -- consecuencia directa de R69: como la credencial nunca
  viaja, activarla/rotarla/revocarla en destino es un acto puramente
  local ahí (vía `/sysadmin/endpoints` DE ESE ambiente), sin relación
  con publicar.
- **R71** -- `mix endpoint.despublicar --sistema=<sistema> <consulta>`
  (comando nuevo, chico, mismo estilo que `motor.despublicar` ya
  existente para catálogos) -- necesario porque, a diferencia de lo
  que se asumió en el primer borrador, acá no hay un `delete_guid`
  real que viaje solo.

### Riesgo conocido, fuera de esta ronda

Si la Consulta ENTERA se borra vía `mix motor.despublicar` (borra el
catálogo real del que depende la Consulta, no el Endpoint en sí), ese
task hoy no sabe de `<consulta>.endpoint.json` -- quedaría un archivo
huérfano sin efecto real. Cosmético, no peligroso; sumarlo a
`despublicar.ex` queda para una vuelta futura si llega a molestar.

## 14. `/sysadmin/endpoints` disponible en cualquier ambiente (R72, agregado 2026-09-17)

**Hallazgo real, probando R67-R71 contra `unstable`:** el catálogo y su
Endpoint llegaron bien, pero `/sysadmin/endpoints` daba "Catálogo no
encontrado" ahí -- esa ruta vivía adentro del mismo bloque `if
Application.compile_env(:metadata_app, :bpb_habilitado)` que apaga
Business Process Builder entero en cualquier release compilado
([router.ex:239](../../../lib/metadata_app_web/router.ex#L239),
heredado de cuando Endpoints vivía adentro de BC List, nunca
revisado al independizarse con R47-51/R66). Esto deja a R69/R70 sin
ningún lugar real donde cumplirse: "crear/rotar una credencial directo
en cada ambiente, vía `/sysadmin/endpoints`" describía una pantalla
que en la práctica no existe fuera de dev/test.

**Verificado leyendo el código (regla del proyecto, nunca asumir)
antes de sacar el gate:** ni `EndpointsLive.mount/3` ni
`ConsultaEndpoints.*` ni `MetaSchemaContext.crear_header_con_detalles/1`
(usada para crear el Header oculto de un Endpoint nuevo) llaman a
`CatalogoGenerador` ni a `Mix` en ningún punto -- a diferencia de un
catálogo BPB real (que sí necesita generar un módulo Ecto y migrar una
tabla física, imposible sin compilador), un `ConsultaEndpoint` es
metadata pura de punta a punta. El gate de BC List nunca aplicó acá,
solo se heredó por estar organizado en el mismo bloque del router.

**Corrección:** las 3 rutas de `Sysadmin.EndpointsLive`
(`router.ex:255-257` original) se sacaron del bloque `bpb_habilitado`
-- siguen dentro de `live_session :app_autenticada`, protegidas
únicamente por el permiso RBAC `sysadmin_endpoints` (R66), que ya era
independiente de esto. `menu_layout.ex`: `"sysadmin_endpoints"` se
movió de `@recursos_plataforma_bpb` a `@recursos_plataforma` -- el
link del menú ahora aparece en cualquier ambiente donde el usuario
tenga el permiso, sin depender de `bpb_habilitado`.

Con esto, R72 queda resuelto: `/sysadmin/endpoints` existe y funciona
igual en local, `unstable`, `testing`, `stable` y cualquier cliente --
generar/rotar/revocar una credencial (R69/R70) ya tiene un lugar real
donde pasar en cada ambiente.

## 15. Publicar/despublicar un Endpoint sin terminal (R73-R75, agregado 2026-09-17)

**Decisión: llamar `MetaPublicador` DIRECTO desde la LiveView, nunca
`Mix.Task.rerun`.** Mismo criterio que ya usa `BcListLive` para su
wizard "Publicar paquete"/"Despublicar de producción" (`bc_list_live.ex:1090`,
`:1078`) -- un `Mix.Task` asume que corre desde una terminal (`Mix.raise`,
`Mix.shell()`), no encaja bien invocado desde un proceso LiveView de
una app ya arrancada. Se reusan las funciones de bajo nivel que ya
comparten el CLI y ese wizard: `MetaPublicador.armar_bundle/1`,
`persistir_bundle/2`, `disparar_deploy/3`.

**Por qué acá no hace falta `mix gen.catalogos` (a diferencia de
`mix motor.publicar`/el wizard de BC List):** la Consulta interna de
un Endpoint es SIEMPRE `schema_context_type: 3`, sin `meta_schema_detail`
propio -- `CatalogoGenerador.generar/1` no genera nada para ella (visto
real en el log: `"x ...: No hay metadata en meta_schema_detail"`, no es
un error, es un no-op). Saltarlo acá no cambia el resultado y evita
duplicar ese paso.

### Piezas nuevas

1. **`ConsultaEndpoints.publicar_a_ambiente/2`** -- exporta el header
   (`MetaSchemaContext.exportar_header/1`), el motor
   (`MetaEstadosAdmin.exportar_header/1`, vacío para una Consulta, pero
   mismo camino que ya usa el CLI) y el propio Endpoint
   (`exportar_endpoint/2`, ya trae `catalogo_base`/`campos`/etc. desde
   R67), y arma+sube+dispara el bundle -- equivalente exacto a `mix
   motor.publicar --sistema=<s> <nombre-interno>`.

2. **`ConsultaEndpoints.despublicar_de_ambiente/2`** (R74 -- NO exige
   que el Endpoint esté borrado local, a diferencia de `mix
   endpoint.despublicar`): escribe el tombstone, arma+sube+dispara el
   bundle igual que el punto 1, y al final vuelve a exportar el
   Endpoint en su forma NORMAL -- el tombstone era solo para ESE
   deploy puntual; en disco, después de esta llamada, todo queda como
   si nunca hubiera pasado (el Endpoint sigue publicado local). El
   Release `bc-<nombre>` en GitHub SÍ queda en la forma tombstone
   hasta la próxima vez que se publique ese mismo Endpoint a algún
   lado -- correcto: "quitado de este ambiente" debe sobrevivir a
   cualquier deploy normal futuro de ESE ambiente, no auto-resucitar.

3. **UI (`EndpointsLive`, tarjeta "Publicación")** -- selector de
   ambiente (misma lista que `BcListLive.sistemas_disponibles/0`:
   `priv/sistemas.json` + `"unstable"`, nunca `testing`/`stable`
   directo) + dos botones, con `start_async/3` (mismo patrón que
   `BcListLive`, la llamada real tarda segundos por la red/`gh`/`tar`).
   Sección visible SOLO si `bpb_habilitado` (R75) -- un release
   compilado no tiene `gh`/`tar` ni sentido como origen de publicación,
   mismo criterio que ya aplica a BC List.

### Cómo quedan resueltos R73-R75

- **R73** -- botones "Publicar a ambiente"/"Quitar de ambiente" en la
  misma pantalla, mismo resultado que los comandos de terminal.
- **R74** -- `despublicar_de_ambiente/2` nunca toca el estado local del
  Endpoint, ni exige que esté borrado -- el tombstone es transitorio,
  solo para el bundle de ESE deploy.
- **R75** -- la sección entera queda detrás de `bpb_habilitado` en la
  UI (la RUTA de Endpoints en sí sigue sin ese gate, R72 -- separado a
  propósito: usar el Endpoint no depende de BPB, pero PUBLICARLO desde
  acá sí depende de tener `gh`/`tar` a mano, que solo existen donde ya
  hoy vive esa herramienta).

## 16. Autoría de un Endpoint, solo en local (R76, agregado 2026-09-18)

**Hallazgo real que motivó esto:** con R72 dejando `/sysadmin/endpoints`
abierto (crear/editar incluido) en cualquier ambiente, se creó sin
querer un Endpoint duplicado directo en `unstable`
(`endpoint_pty_h_historico_499`) -- exactamente la deriva que el resto
de la plataforma ya evita para catálogos (nunca se autorían en
producción). R72 se revisa: solo "ver + credenciales + documentación"
sigue siendo universal; crear/editar la definición vuelve a depender
de `bpb_habilitado`, igual que BC List.

### Cambios

1. **`router.ex`** -- `live "/sysadmin/endpoints/nuevo", ..., :nuevo`
   vuelve DENTRO del bloque `if bpb_habilitado` (con BC List/Tepache).
   `:index`/`:editar` (la lista y "Configurar") se quedan FUERA de ese
   bloque, sin cambios -- ahí es donde vive ver/credenciales/docs.

2. **`EndpointsLive`** -- `bpb_habilitado` se asigna una sola vez en
   `mount/3` (antes estaba duplicado en el `cargar/3` de `:editar`), y
   se pasa como `attr` a `vista_index/1` y `vista_editar/1` (son
   function components -- tienen su assigns propio, aislado del
   `socket.assigns` del LiveView; hallazgo real de la vuelta anterior,
   R73-75, mismo tipo de bug si no se pasa explícito).
   - `vista_index`: "+ Nuevo endpoint" y "Eliminar" (por fila) quedan
     `:if={@bpb_habilitado}`.
   - `vista_editar`: el panel de Campos, la tarjeta "Configuración del
     endpoint" (+ "Alta de registros"), "Probar" y "Publicación"
     (toggle local + la sección "Ambientes" de R73-75, que ya estaba
     gateada) quedan `:if={@bpb_habilitado}` -- "Credenciales" y
     "Documentación" NO llevan ese gate, siguen universales (R72). Sin
     BPB, un aviso explica por qué no se puede editar ahí.
   - **Defensa en profundidad**: un `handle_event/3` genérico, ANTES
     de las cláusulas específicas (el orden de definición importa acá
     -- Elixir prueba las cláusulas en el orden en que aparecen en el
     archivo), corta cualquier evento de la lista `@eventos_solo_bpb`
     (crear, guardar, eliminar, marcar campos, alta, probar,
     publicar/despublicar LOCAL) si `bpb_habilitado` es `false` -- la
     UI ya los oculta, esto cubre un evento disparado igual (ej. con
     el socket ya montado). Los eventos de credenciales quedan afuera
     de esa lista a propósito.

### Cómo queda resuelto R76

Crear/editar la definición de un Endpoint vuelve a depender de
`bpb_habilitado`, en el router Y en la UI Y en el `handle_event` --
tres capas, mismo criterio de "defensa en profundidad" que ya usa el
resto del proyecto. Ver/credenciales/documentación siguen sin cambios
(R72), disponibles en cualquier ambiente.
