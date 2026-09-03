# SPEC-SYS-0209202601 — Parámetros y Totales para Catálogos (BC)

**Documento:** Requirements · **Fase:** ✅ aprobada (2026-09-02).

## 1. Propósito

Hoy el sistema tiene dos formas de mostrar una tabla de datos:

- **Catálogo (BC)** — `CatalogoGenerico`/`CatalogoLive`, sobre una tabla física real.
- **Consulta Ecto** — `MetaConsultas`/`consulta_editor_live.ex`, sobre una definición de columnas guardada en JSON, con un sistema maduro de **Parámetros** (filtros con widget real para el usuario final) y de **Totales** (Suma/Promedio/Conteo en la fila de Resumen).

Un Catálogo (BC) normal HOY solo tiene una versión más simple/separada de "Totales" (sección "Filtros" del Get Config: Mín./Máx., Total 25, Totalizado, Máscara, Valor por default, Bloqueado) y **no tiene ningún sistema de Parámetros** — el usuario final no puede pedirle a la tabla "fecha entre X e Y" ni "nombre que contenga Z" con un widget dedicado, más allá de los filtros genéricos de columna que ya existan.

Este spec lleva el sistema de **Parámetros** de Consultas a los Catálogos (BC) normales, y decide qué pasa con "Totales" en el proceso.

## 2. Alcance

**Incluye:**
- Un catálogo (BC) normal puede marcar columnas propias como "Parámetro" (Get Config → Columnas del GET), igual que hoy puede una Consulta.
- El usuario final ve el mismo widget de filtro rápido (`panel_parametros`, ya existente) arriba de la tabla de un catálogo normal — hoy solo aparece para Consultas.
- Los 4 tipos ya soportados por Consultas (fecha, string, referencia, numérico) con sus mismas reglas (acotado, tipo de filtro, origen libre/referenciado, defaults) — se reusa la lógica existente de `MetaConsultas`, no se reinventa.

- Se aplica parejo a TODOS los catálogos (BC) del motor — sin excepciones por `alcance_habilitado`, `schema_es_transaccional`, ni ningún otro flag. Incluye los catálogos de la spec anterior (`pty_folio_perfiles`, `pty_subtipos_transaccion`).
- La sección "Filtros" (Totales) de hoy se retira — su funcionalidad pasa a vivir dentro de "Columnas del GET" (ver §3).
- **Unificación total, no solo visual (resuelto 2026-09-02, a pedido explícito — "quiero que sea lo más estandarizado posible, que parezcan ser la misma config")**: el ícono de embudo por columna que HOY ya usa un catálogo (BC) para filtrar (`fila_filtro_columna`/`celda_encabezado`, popover en el encabezado de cada columna) se RETIRA — pasa a usarse el mismo panel acordeón de Parámetros que hoy es exclusivo de Consultas (`panel_parametros`), para los dos por igual. Un solo sistema de filtro para el usuario final, sea BC o Consulta.

**No incluye:**
- Ningún tipo de parámetro nuevo que Consultas no tenga ya.
- Cambios al comportamiento de Parámetros/Totales que ya ve un usuario de Consultas — la experiencia de Consultas no cambia, solo se generaliza para que un BC la comparta.

## 3. Totales ("Tot.") — resuelto

La sección "Filtros" de hoy (Mín./Máx., Total 25, Totalizado, Máscara, Valor por default, Bloqueado) **se fusiona** dentro de la misma grilla de "Columnas del GET" — una columna "Tot." más, con sus sub-opciones agrupadas (popover o celdas expandibles, a definir en design.md), igual criterio visual que Param/Tipo/Acot./Default. La sección "Filtros" separada desaparece — todo Get Config de un catálogo vive en una sola grilla.

**"Default" se unifica**: el "Valor por default" que ya existía en Filtros y el "Default" de Parámetro (Consultas) son el MISMO concepto — un solo valor/rango inicial por columna, sea cual sea el propósito (totalizar o filtrar). Una sola celda "Default" en la grilla, no dos.

## 4. Requisitos funcionales (borrador — EARS)

### R1. Marcar una columna como Parámetro
CUANDO un administrador marca una columna visible de un catálogo (BC) como "Parámetro" en Get Config, EL SISTEMA DEBE ofrecer la misma configuración (Tipo de filtro, Acotado, Defaults) que ya ofrece para una Consulta, según el tipo de dato real de la columna.

### R2. Un solo widget de filtro para el usuario final
CUANDO un catálogo (BC) tiene al menos una columna marcada como Parámetro, EL SISTEMA DEBE mostrarle al usuario final el mismo panel de filtros rápidos (`panel_parametros`) que ya ve en una Consulta, aplicando el filtro elegido sobre la tabla real del catálogo — en reemplazo del ícono de embudo por columna que existe hoy solo para catálogos (BC). No conviven los dos sistemas.

### R3. Reuso, no reinvención
CUANDO se aplica un filtro de Parámetro sobre un catálogo (BC), EL SISTEMA DEBE usar la misma lógica de `MetaConsultas.aplicar_filtros_*_estandar` (generalizada si hace falta) — no una implementación paralela.

### R4. Totales unificados en la grilla — para BC y Consulta por igual (ampliado 2026-09-02, a pedido explícito)
CUANDO un administrador configura un campo numérico (integer/decimal) de un catálogo (BC) **o de una Consulta** en su Get Config, EL SISTEMA DEBE ofrecer las mismas opciones (Mín./Máx., Total 25, Total general, Máscara) — sin una sección aparte, y sin diferencia entre BC y Consulta. El "Totalizar" simple que hoy tiene Consulta se sube al mismo nivel que ya tiene BC — no quedan dos niveles de Totales distintos.

### R5. Default unificado
CUANDO un campo tiene un valor/rango por default configurado, EL SISTEMA DEBE usar UN SOLO valor — el mismo sea cual sea el uso (totalizar con un valor inicial, o filtrar con Parámetro).

### R6. Sin excepciones por catálogo
CUANDO cualquier catálogo (BC) del motor pasa por Get Config, EL SISTEMA DEBE ofrecerle el mismo sistema de Parámetros/Totales/Default — ningún catálogo queda afuera por sus otros flags (transaccional, alcance de datos, etc.).

## 5. Preguntas abiertas

Ninguna pendiente — las 3 que estaban acá se resolvieron y ya están incorporadas: Totales fusionado en Columnas del GET (§3, R4), Default unificado (§3, R5), aplica a todos los catálogos sin excepción (§2, R6).
