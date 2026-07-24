# Roadmap — Campos de acompañamiento (enriquecimiento vía referencia)

> Este documento es una especificación para implementar más adelante — **nada de esto está construido todavía**. Nace de una conversación de diseño (2026-07-24) sobre el catálogo `pty_ecc_clientes`/`pty_ecc_empresas`/`pty_ecc_segmentos`, pero la feature es genérica para cualquier catálogo con un campo tipo `"referencia"`.

## El problema

Un campo tipo `"referencia"` (ej. `cliente_ecc` en `pty_ecc_empresas`, que apunta a `pty_ecc_clientes`) hoy solo guarda el `id` del registro relacionado. Al consultar `GET /api/pty_ecc_empresas`, la fila trae `"cliente_ecc": 1` en crudo — para saber el nombre del cliente hay que hacer una segunda consulta manual.

Se quiere que ese `GET` (y la tabla de `CatalogoLive`) puedan traer, ya resueltos, algunos campos del catálogo referenciado — sin que el cliente de la API tenga que resolver la relación a mano.

## Precedente ya existente en el código (base para esto)

Esto no es un patrón nuevo — ya existe uno igual para `estado_nombre`:

- [`meta_state_engine.ex`](../lib/metadata_app/meta_state_engine.ex) tiene `mapa_nombres_estados/1`, que arma **una sola vez por request** un mapa `%{estado_id => nombre}` con todos los estados del catálogo (batch).
- [`catalogo_generico.ex:249`](../lib/metadata_app/business_process_builder/catalogo_generico.ex#L249) — `serializar/2` usa ese mapa para agregarle `estado_nombre` a cada fila, sin una query por fila.

La implementación de "campos de acompañamiento" debería seguir exactamente esta forma: **una query batch por relación por página de resultados**, nunca una query por fila (N+1).

## Decisiones ya tomadas

| Punto | Decisión |
|---|---|
| Dónde se configura | En la propiedad del campo, **a dos niveles**: encabezado (header) del catálogo referenciado + detalle (el campo `referencia` que consume la relación). Ver modelo de datos abajo. |
| Forma del JSON | **Anidado**, no plano con prefijo: `"cliente_ecc": {"id": 1, "razon_social": "..."}`, no `"cliente_ecc_razon_social": "..."`. |
| Dónde aplica | **GET estándar de la API** y **tabla de `CatalogoLive`** (mismo dato debe alimentar ambos caminos). |
| Editable | **No.** Solo lectura, igual que `estado_nombre` — se rechaza igual que `estado_id`/`trn`/`ulid` si llega en un `PATCH` (ver `rechazar_no_editables/4` en `catalogo_generico.ex`). |
| Encadenado | **No.** Un campo de acompañamiento no puede a su vez traer sus propios campos de acompañamiento — profundidad máxima 1, para evitar referencias circulares y cascadas de queries. |

## Modelo de datos propuesto (dos niveles)

**A nivel header** (`meta_schema_header`, el catálogo que ES la referencia — ej. `pty_ecc_clientes`): declara qué campos de SÍ MISMO autoriza a exponer hacia catálogos que lo referencian. Es una whitelist del lado "uno" de la relación — evita que cualquier catálogo que apunte a este pueda pedir traerse cualquier campo sin que el dueño del catálogo lo haya habilitado.

```jsonc
// nueva propiedad en meta_schema_header (columna nueva, hoy no existe
// ninguna bolsa libre tipo "properties" en Header — hay que agregarla)
"campos_exportables": ["razon_social", "no_rutas", "no_sucursales"]
```

**A nivel detail** (`meta_schema_detail`, el campo tipo `"referencia"` del catálogo que CONSUME la relación — ej. `cliente_ecc` en `pty_ecc_empresas`): de ese conjunto exportable, cuáles trae específicamente esta relación en particular.

```jsonc
// dentro de schema_context_properties del campo "cliente_ecc"
{
  "tipo": "referencia",
  "catalogo": "pty_ecc_clientes",
  "campos_acompanamiento": ["razon_social", "no_rutas"]   // ⊆ campos_exportables del header de pty_ecc_clientes
}
```

Validación a construir: al guardar `campos_acompanamiento` en el detalle, rechazar cualquier campo que no esté en `campos_exportables` del header del catálogo destino (mismo espíritu que `validar_campos_editables/1` ya hace hoy en `MetaEstadosAdmin` para `campos_editables` de una transición).

## Forma de la respuesta (GET)

```jsonc
// GET /api/pty_ecc_empresas
{
  "data": [
    {
      "id": 1,
      "nombre_empresa": "Bepensa Bebidas SA de CV",
      "cliente_ecc": {
        "id": 1,
        "razon_social": "COCA COLA FEMSA",
        "no_rutas": 50
      },
      "estado_nombre": "Activo"
    }
  ]
}
```

`cliente_ecc` deja de ser un entero plano y pasa a ser un objeto — **esto es un cambio de shape que rompe compatibilidad** con cualquier cliente de la API actual que espere el id plano. Hay que decidir, al implementar, si esto se activa siempre que el campo tenga `campos_acompanamiento` configurado (breaking) o si se ofrece como un parámetro opt-in del request (ej. `?incluir=cliente_ecc`, no rompe nada, pero es más trabajo). Documentar la decisión que se tome.

## Dónde vive la resolución (evitar N+1)

Mismo lugar/patrón que `estado_nombre`, extendido:

1. El controller (o `CatalogoLive`, para el camino de la tabla) arma, **una vez por página de resultados**, un mapa por cada campo `referencia` con `campos_acompanamiento` configurado: `%{id_referenciado => %{campo => valor}}`, con **una sola query batch** (`WHERE id IN (...)`) contra el catálogo destino.
2. `CatalogoGenerico.serializar/2` (o una función hermana) usa esos mapas para anidar el objeto en cada fila — sin tocar la base de datos fila por fila.

## Fuera de alcance para v1 — Fase 2 (roadmap)

Explícitamente pospuesto, no se construye ahora:

- **Búsqueda/filtro sobre campos de acompañamiento.** "Buscar en cualquier columna" y los filtros de `CatalogoLive` no van a alcanzar estos campos — no son columnas reales de la tabla física, buscar ahí requeriría un `JOIN` real en la query de listado (no solo en el serializador post-query), que es una historia aparte.
- **Encadenado / profundidad > 1.** Si algún día se necesita (ej. traer un campo de acompañamiento de un catálogo que a su vez trae otro), evaluar entonces — hoy se cierra la puerta a propósito.
- **Dirección inversa ("uno → muchos").** Lo que se armó en esta conversación es la dirección "muchos → uno" (el catálogo que tiene el FK se enriquece con datos del catálogo referenciado). La dirección contraria — que `pty_ecc_clientes` muestre un conteo/lista real de `pty_ecc_empresas`/`pty_ecc_segmentos` que lo referencian a ÉL — es una feature distinta (agregación, no join simple) y no está cubierta por este documento. Hoy esos campos (`empresas`, `segmentos` en `pty_ecc_clientes`) son enteros manuales sin relación real con las tablas nuevas.

## "Prompt" para retomar esto en una sesión futura

Cuando se vaya a implementar, este bloque alcanza como punto de partida (autocontenido, no depende de recordar esta conversación):

> Implementa "campos de acompañamiento" según `docs/roadmap-campos-acompanamiento.md`: un campo tipo `"referencia"` en el contrato de un catálogo (`meta_schema_detail`) debe poder declarar `"campos_acompanamiento"` (subconjunto de `"campos_exportables"` que declara el `meta_schema_header` del catálogo referenciado). El `GET` estándar de la API y la tabla de `CatalogoLive` deben anidar esos campos como objeto (`"cliente_ecc": {"id":..., "razon_social":...}`), resueltos en una sola query batch por página (mismo patrón que `estado_nombre` en `catalogo_generico.ex`/`meta_state_engine.ex` — revisar esos dos archivos primero). Solo lectura (rechazar si llega en un PATCH, igual que `estado_id`). Sin encadenar (profundidad máxima 1). Fuera de alcance: búsqueda/filtro sobre estos campos, y la dirección inversa "uno a muchos" (conteos de catálogos que referencian a este). Antes de escribir código, confirmar con el usuario la decisión pendiente marcada en el documento (shape breaking vs. opt-in por query param) y si `campos_exportables` se agrega como columna nueva en `meta_schema_header` o se reusa algún campo existente.
