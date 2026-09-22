# SPEC-SYS-0209202601 — Parámetros y Totales para Catálogos (BC)

**Documento:** Design · **Fase:** ✅ aprobada (2026-09-02).

## 0. Decisión de rollout — sin migración automática (2026-09-02, a pedido explícito)

Retirar el embudo/"Filtros" (fila_filtro_columna, panel_filtros, celda_encabezado)
en favor de `panel_parametros` es un cambio real de UX para el usuario
final: HOY puede filtrar cualquier columna visible sin que un admin
configure nada; DESPUÉS solo puede filtrar las columnas que un admin
marcó "Parámetro" en Get Config. Como ningún catálogo tiene ese flag
prendido todavía (es capacidad nueva del Grupo D), esto significa que
al desplegar, todo catálogo BC pierde su filtrado de filas hasta que un
admin lo reconfigure a mano, catálogo por catálogo. Se preguntó
explícitamente si migrar automáticamente (marcar `es_parametro: true`
en todo campo hoy filtrable) — **se decidió que NO**: queda en cero, tal
cual estaba en tasks.md, a criterio del usuario.

## 1. Arquitectura de integración

### 1.1 Lo que ya está compartido (no se toca)

`CatalogoGenerico.aplicar_filtros/2` es el motor de filtrado real, y YA es
compartido: tanto `CatalogoLive` (camino BC) como `MetaConsultas.ejecutar/6`
(camino Consulta) arman su `filtros_ecto` y se lo pasan a la misma función.
Este spec no toca esa capa — el filtrado en sí ya es uno solo.

### 1.2 Lo que hoy está DUPLICADO y hay que unificar

| Concepto | Hoy en BC | Hoy en Consulta | Después de este spec |
|---|---|---|---|
| Dónde vive la config por campo | `meta_schema_detail.schema_context_properties` (jsonb, un campo real por fila) | `meta_schema_consulta.campos` (jsonb, un array completo en una sola columna) | Sin cambio en el storage de cada uno — se unifica el SHAPE de las claves nuevas (ver §2), no dónde viven |
| UI de "es esto un filtro" | Ícono de embudo por columna (`fila_filtro_columna`, `celda_encabezado`) | Botón "Parámetro" en Get Config | **Se retira el embudo** — el toggle vive en Get Config para los dos |
| Widget que ve el usuario final | Popover por columna en el `<th>` | Panel acordeón `panel_parametros` arriba de la tabla | **`panel_parametros` para los dos** |
| Config rica (tipo de filtro/acotado/origen) | No existe | `es_parametro`/`tipo_filtro`/`acotado`/`origen`/`catalogo_referenciado`/`defaults` | BC adopta el mismo shape |
| "Bloqueado" (usuario no puede tocar el filtro) | Sí existe (`filtro_default_bloqueado`) | No existe | Se agrega a Consultas también (mismo shape, ver §2) — efecto colateral de unificar, no पedido explícito pero necesario para que sea "la misma config" |
| Totales (Suma/Promedio/Conteo) | Rico: Mín./Máx., Total 25 (página), Total general, Máscara (`agregacion_activa` + 4 sub-flags) | Simple: un solo booleano `"totalizar"` | **Se sube Consulta a la par de BC** (2026-09-02, a pedido explícito — "ocupo totalizar"): Consulta adopta el mismo shape rico (`agregacion_activa` + 4 sub-flags), reemplaza su `"totalizar"` booleano. `MetaConsultas.ejecutar/6` (banda de totales, `totales/3`) se generaliza junto con el resto del motor de parámetros (§1.4) para leer el shape nuevo. |

### 1.3 Punto de enganche nuevo: `CatalogoLive`, camino `modulo` (BC)

`cargar_filas_catalogo/1` (línea ~907) es el único lugar que arma la lista de
filas para un BC. Hoy solo pasa `filtros_ecto` (de los filtros normales de
columna) y `orden` (SPEC-SYS-0109202601). Se le suma un tercer insumo:
`overrides_parametro` — MISMO nombre y MISMA forma que ya usa el camino
`consulta` (línea ~873/895), convertido a `filtros_ecto` con la misma
lógica de traducción que hoy es privada de `MetaConsultas`.

### 1.4 Generalizar `MetaConsultas` → nuevo módulo compartido

`campos_elegibles_string/1`, `campos_elegibles_numerico/1`,
`campos_elegibles_fecha/1`, `tipo_elegible?/1`, `tipo_efectivo/1`,
`aplicar_filtros_string_estandar/4`, `aplicar_filtros_numerico_estandar/4`,
`aplicar_filtros_fecha_estandar/4` hoy reciben o devuelven cosas atadas a
`%Consulta{}` (ej. `consulta.campos`, `catalogo_base`). Se extraen a un
módulo nuevo, **`MetadataApp.ParametrosCatalogo`**, que opera sobre:

- `campos :: [map()]` — lista de mapas planos `%{"catalogo" =>, "campo" =>, "etiqueta" =>, "tipo" =>, "es_parametro" =>, ...}` (mismo shape que ya usa `consulta.campos`, ver §2).
- Nunca un `%Consulta{}` ni un `%Detail{}` reales — así sirve para los dos orígenes de datos sin acoplarse a ninguno.

`MetaConsultas` pasa a ser un adaptador fino: convierte `consulta.campos`
(ya viene en el shape correcto, sin transformar nada) y llama a
`ParametrosCatalogo`. `CatalogoGenerico`/`CatalogoLive` (o un adaptador
nuevo, `MetaSchemaContext.campos_como_parametros/1`) convierte los
`%Detail{}` de un catálogo BC al mismo shape, aplicando `es_parametro`/
`tipo_filtro`/etc. desde `schema_context_properties` (ver §2) — y llama a
la MISMA `ParametrosCatalogo`.

`panel_parametros` (hoy en `catalogo_live.ex`, privado) se mantiene donde
está — ya es agnóstico de origen (solo recibe `parametros_string`/
`parametros_numerico`/`parametros_fecha`/`overrides_parametro` ya armados),
no necesita moverse ni cambiar.

## 2. Modelo de datos — shape unificado por campo

Nueva forma de `schema_context_properties` para un campo de negocio de un
catálogo BC (`meta_schema_detail`) — se agregan las claves que ya usa
`consulta.campos` (ver moduledoc de `MetaSchema.Consulta`), sin quitar
ninguna de las que ya existen (`tipo`, `etiqueta`, `visible`, `editable`,
`opcional`, `orden`, ...):

```jsonc
{
  // ... lo que ya existe ...

  // Parámetro (nuevo en BC, ya existía en Consulta)
  "es_parametro": false,
  "tipo_filtro": null,          // "like"|"igual"|"multi" (string/ref) | "mayor"|"menor"|"igual"|"diferente"|"entre" (numérico) | n/a (fecha, lo decide "acotado")
  "acotado": false,
  "origen": null,               // "libre" | "referenciado" -- solo string/referencia
  "catalogo_referenciado": null,

  // Default — UNIFICADO (antes "filtro_default_valor"/"_desde"/"_hasta" en BC)
  "defaults": {},               // shape según tipo, igual a Consulta (ver moduledoc)

  // Bloqueado — YA existía en BC como "filtro_default_bloqueado", se
  // renombra a "bloqueado" para que el nombre sea el mismo en los dos
  // lados (Consulta lo adopta acá por primera vez)
  "bloqueado": false,

  // Totales -- YA existían en BC, se quedan TAL CUAL, ahora renderizados
  // dentro de la misma grilla en vez de la sección "Filtros" aparte
  "agregacion_activa": false,
  "minmax_recomendado": false,
  "total_pagina_activo": false,
  "total_general_activo": false,
  "mascara_separador": ",",
  "mascara_simbolo": ""
}
```

**Migración de datos existentes** (catálogos que YA configuraron Filtros
hoy): un script de datos (Tasks) recorre `meta_schema_detail`, y por cada
fila con alguna de `filtro_default_valor`/`filtro_default_desde`/
`filtro_default_hasta` no nula, arma el `defaults` nuevo con la MISMA
forma que ya usa Consulta (`%{"valor" => ...}` o `%{"valor" =>,
"valor_hasta" =>}`), y renombra `filtro_default_bloqueado` → `bloqueado`.
Las claves viejas se borran del jsonb (no quedan huérfanas). Sin esto,
cualquier BC que ya tenga un default configurado (ej. `pty_gasto_diariov2`)
lo perdería en silencio.

**`consulta.campos`** (Consulta) — dos cambios de shape, los dos vía el
mismo script de migración de datos que corre sobre `meta_schema_detail`
(§ arriba), pero acá sobre cada fila de `meta_schema_consulta`:
- Se agrega `"bloqueado"` (default `false`) a cada entrada.
- `"totalizar": true` se reemplaza por `"agregacion_activa": true` +
  el resto de sub-flags en `false` (equivalente exacto al "Totalizado"
  de BC hoy — mismo significado, "suma/cuenta TODO lo que matchea el
  filtro", no solo la página) — así una Consulta que ya totalizaba una
  columna sigue totalizándola después de la migración, con el mismo
  número, solo que ahora con Mín./Máx./Total 25/Máscara disponibles
  además si el admin los quiere prender.

## 3. UI — grilla única "Columnas del GET"

Mismas 9 columnas que ya tiene Consultas (`panel_get_config` →
`get-config-columnas`), reusando esos mismos sub-componentes
(`celdas_parametro`, `toggle_es_parametro`, `selector_tipo_filtro`,
`toggle_acotado`, `defaults_fecha`/`defaults_string`/`defaults_numerico`,
`origen_string`, `selector_catalogo`) — se MUEVEN de `consulta_editor_live.ex`
a un módulo de componentes compartido, **`MetadataAppWeb.ParametrosCatalogoComponents`**,
para que `bc_motor_live.ex` los use tal cual, sin copiar/pegar.

`Tabla | Campo | Etq | Vis. | Tot. | Param | Tipo | Acot. | Default` — en
un BC no hay `Tabla` (una sola tabla siempre, igual que Consultas
`multi_tabla?: false` ya lo oculta hoy). `Tot.` pasa a ser rica (4
sub-opciones vía popover en la celda) EN LOS DOS — Consulta también, ya no
un simple check — el popover de Totales es un componente nuevo (hoy son
botones sueltos en filas separadas de `panel_filtros_resumen`, solo en
BC), armado con el mismo patrón visual que ya usan
`defaults_numerico`/`defaults_fecha` (celda con botones toggle adentro),
y agregado también a `panel_get_config` (Consultas) en la columna `Tot.`
que hoy es un checkbox simple.

`panel_get_view` (bc_motor_live.ex) pasa a tener 2 secciones en vez de las
4 de hoy (Columnas del GET unificada + Orden de resultados, ya armado en
SPEC anterior) — `panel_filtros_resumen` se retira completo, su contenido
migra a la grilla.

## 4. Riesgo — blast radius

Esto toca el render de TODOS los catálogos (BC) del sistema (R6, sin
excepción), TODAS las Consultas ya publicadas (R4 ampliado — su fila de
Resumen/Totales cambia de motor), y retira código en producción
(`fila_filtro_columna`, `celda_encabezado`, `panel_filtros_resumen`). Plan
de mitigación:

- Migración de datos (§2) corre y se verifica ANTES de tocar ningún
  render — un catálogo con Filtros configurados hoy no puede perder su
  default al desplegar esto.
- `ParametrosCatalogo` (motor compartido nuevo) se prueba primero AISLADO
  contra ambos orígenes de datos (fixture BC + fixture Consulta) antes de
  enganchar ningún LiveView — mismo criterio que
  `IdentificadoresTransaccionales` en la spec anterior (Grupo D).
- Regresión explícita: una Consulta ya en uso (con Parámetros configurados
  HOY) tiene que seguir funcionando exactamente igual después del refactor
  de `MetaConsultas` → `ParametrosCatalogo` — test de regresión dedicado.
