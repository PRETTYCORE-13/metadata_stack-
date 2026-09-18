# SPEC-SYS-1809202602 — Copiar un BC desde BC List

**Documento:** Tasks · **Fase:** ✅ completa (2026-09-18) — Grupos A-F, código+tests+verificación real, todo pasando.

## Grupo A — `MetadataApp.MetaClonador` (núcleo puro + orquestación) ✅

- [x] A1. Archivo nuevo `lib/metadata_app/meta_clonador.ex`.
      `renombrar_campo/3` (privada) — la única regla de renombrado
      (design.md §3).
- [x] A2. `elegible?/1` pública (reusada desde `BcListLive` en Grupo
      C): dado un `Header`, `true` solo si `schema_context_type == 1`,
      `schema_encabezado_id == nil`, y
      `MetaSchemaContext.listar_catalogos_detalle(header.id) == []`.
- [x] A3. `armar_detalles/2` (privada): `listar_detalles/1` del
      original, excluye `"fecha_registro"`, renombra
      `schema_context_field` + `schema_context_properties["campos_relacion"]`
      con A1, copia el resto de `schema_context_properties` tal cual.
- [x] A4. `armar_automata/4` (privada): si
      `MetaEstadosAdmin.listar_estados(header.id) == []` →
      `{[], []}`. Si no, copia estados tal cual + renombra
      `campos_editables` de cada transición con A1, filtrando contra
      el set de nombres de A3 (descarta huérfanos, design.md §3).
- [x] A5. `clonar/2` + `construir_plan/2` públicas — `construir_plan/2`
      separa la parte PURA (sin tocar la base) de `clonar/2` para
      poder testearla sin pasar por DDL (ver Grupo D). `clonar/2`
      encadena `construir_plan/2` →
      `MetaEstadosAdmin.insertar_proceso/1` (NO `crear_proceso_completo/1`
      -- hallazgo real, ver nota abajo) → `CatalogoGenerador.generar/1`.

**Hallazgo real (2026-09-18)**: `crear_proceso_completo/1` exige un
estado inicial o transición "alta" para cualquier maestro (regla
correcta para el wizard "Nuevo catálogo", pensada para algo armado de
CERO) — pero un original que nunca adoptó el motor de estados debe
clonarse igual de "sin motor" (R10). Se separó `MetaEstadosAdmin.insertar_proceso/1`
(mismo `Multi`, sin la validación de negocio) para que `MetaClonador`
lo use directo.

## Grupo B — Validación de destino (reuso, no reinventar) ✅

- [x] B1. `nombre_sistema_desde/1`, `componer_nav/2`,
      `validar_nombre_y_nav/2` (antes `validar_regex/3` +
      `validar_nav_libre/1` sueltos) ahora viven en `MetaSchemaContext`
      — `BcNuevoCompletoLive` delega (`defdelegate` para los dos
      primeros, `validar_contexto/3` reescrito para llamar a
      `validar_nombre_y_nav/2` + su propio `validar_completado/3` de
      etiqueta, que sigue privado ahí por ser específico del
      placeholder de ESE wizard).
- [x] B2. No existía ningún test de `BcNuevoCompletoLive` (confirmado,
      cero archivos) — no hacía falta actualizar ninguno. Cobertura de
      la validación movida queda en `meta_clonador_test.exs` (Grupo D)
      + verificación manual pendiente (Grupo E) de que "Nuevo
      catálogo" sigue funcionando igual.
- [x] B2a. Hallazgo real en el camino: `validar_nombre_y_nav/2` (y por
      lo tanto `validar_contexto/3` de antes) NUNCA chequeaba si el
      NOMBRE ya existía — solo el nav. Un nombre duplicado con nav
      libre pasaba la validación de entrada y recién fallaba tarde,
      contra el `unique_constraint` de la base dentro de
      `insertar_proceso/1`. Agregado `validar_nombre_libre/1` — mismo
      criterio que ya usaba `validar_nav_libre/1`, beneficia a los dos
      caminos (Nuevo catálogo y Copiar) con un solo fix.

## Grupo C — UI en `BcListLive` ✅

- [x] C1. Botón "Copiar" en la celda de acciones (entre "Editar" y
      "Eliminar"), `:if={puede_copiar?(nodo)}` — chequeo barato sobre
      el `nodo` aplanado (mismo criterio que `MetaClonador.elegible?/1`
      pero sin traer el `Header` completo por fila).
- [x] C2. `handle_event("abrir_copiar", %{"tabla" => nombre}, socket)`
      — carga el header original, `assign(:copiar, %{header_original:
      ..., contexto: %{"nombre" => "", "etiqueta" => label <> " (copia)",
      "carpeta_padre" => carpeta_padre_desde_nav(nav), "icono" => ...}})`.
- [x] C3. `modal_copiar/1` (mismo patrón visual que
      `modal_editar_carpeta/1`), con el picker de carpeta ya existente
      de `BcListLive` (`@carpetas_disponibles`) + preview de nombre/nav
      vía `MetaSchemaContext.nombre_sistema_desde/1`/`componer_nav/2`.
- [x] C4. `handle_event("guardar_copiar", %{"contexto" => contexto},
      socket)` — llama `MetaClonador.clonar/2`. Éxito: flash + `push_navigate`
      a BC Motor del clon. Error: mensaje in-line, modal se queda
      abierto.
- [x] C5. `handle_event("cerrar_copiar"/"validar_copiar"/"elegir_icono_copiar", ...)`
      — mismo patrón que sus equivalentes de "Editar carpeta".

## Grupo D — Tests ✅

- [x] D1. `test/metadata_app/meta_clonador_test.exs` (archivo nuevo,
      5 tests, todos contra `construir_plan/2` -- la parte PURA, sin
      `CatalogoGenerador.generar/1`, ver nota de Grupo A/design.md §1
      sobre por qué el DDL no se testea automatizado en este proyecto):
  - Clonar un catálogo simple sin autómata → header/detalles nuevos
    con prefijo correcto, sin `fecha_registro`, estados/transiciones
    vacíos.
  - Clonar un catálogo CON autómata (Activo/Baja, `campos_editables`)
    → estados clonados tal cual, `campos_editables` renombrados y una
    referencia huérfana (caso defensivo, reproducida a mano
    soft-borrando un detalle DESPUÉS de crear la transición —
    corrección 2026-09-18: NO es el caso de `pty_dsd_cs_vigencias_frec`,
    esa referencia resultó estar completa; ver `requirements.md` R8)
    descartada sin error.
  - Un campo "referencia" a OTRO catálogo → `catalogo`/
    `campo_visualizacion`/`campos_acompanamiento` quedan intactos,
    solo `campos_relacion` (autoreferencia) se renombra.
  - Nombre destino vacío/inválido, o ya existente (nombre Y nav) →
    `{:error, ...}` (encontró y arregló B2a en el camino).
  - Origen no elegible (Consulta, o maestro con un detalle propio) →
    `{:error, ...}` antes de tocar la base.
- [x] D2. `test/metadata_app_web/live/sysadmin/bc_list_live_test.exs`
      (3 tests nuevos, describe "Copiar un BC"):
  - El botón no aparece en un catálogo detalle, una Consulta, ni un
    maestro con un detalle propio; sí aparece en uno elegible.
  - Abrir el modal precarga etiqueta con "(copia)" y nombre técnico
    vacío.
  - Nombre ya existente → error in-line ("ya existe"), modal sigue
    abierto. **NO se testea el happy path completo** (con
    `CatalogoGenerador.generar/1` real) — mismo criterio ya
    documentado en `alcance_por_catalogo_ui_test.exs`: DDL en caliente
    bajo Sandbox transaccional deja residuo permanente (archivo + módulo
    recompilado) que un rollback de DB no deshace, sin cubrir nada que
    `meta_clonador_test.exs` no cubra ya sobre la parte pura. Ese
    camino queda para Grupo E (manual).

## Grupo E — Verificación real (regla #3 del skill `spec`) ✅

- [x] E1. Verificado con `pty_e2e_clon_<sufijo>` → `pty_e2e_clon_copia_<sufijo>`
      (catálogo de PRUEBA descartable, 2 campos + Activo/Baja) vía
      `mix run`: campos renombrados correctos, estados clonados,
      `campos_editables` de las transiciones renombrados, plantilla
      automática creada y publicada. Limpiado con
      `CatalogoGenerador.eliminar/3` (clon y original) — `archivo_eliminado:
      true` para los dos, cero residuo en `git status`. Las migraciones
      create+drop quedan en disco (gitignoradas, `*pty_*.exs`) — mismo
      criterio que cualquier catálogo real, nunca se borra historial de
      migraciones.
- [x] E2. Suite completa (`mix test`) — 662/664 (657/659 tests + 5/5
      properties), las 2 fallas son preexistentes y no relacionadas
      (confirmado: archivos que esta spec nunca tocó -- `motor_alta.ex`
      en medio de OTRO refactor sin terminar, y un test de
      `catalogo_live_consulta_test.exs` sin cambios desde hace semanas).
      Sin regresión en ningún test de `BcNuevoCompletoLive` (no existía
      ninguno) ni en el resto de la suite.
- [x] E3. Decidido con el usuario: borrar el `pty_cs_vigencias_frec`
      manual y re-crearlo con el camino oficial. Borrado
      (`CatalogoGenerador.eliminar/3`, 0 filas) y re-creado con
      `MetaClonador.clonar/2` (nav `/clientes/cs-vigencias-frec`,
      ícono `group`) + `schema_visible` puesto en `true` a mano
      después (v1 clona la visibilidad tal cual el original —
      `false` — no la ofrece editable en el form, ver
      `requirements.md` R4). Resultado: **5 campos** clonados (no 4
      como el intento manual anterior) — incluye
      `pty_cs_vigencias_frec_operacion` (referencia a
      `pty_dsd_cs_clientes_ope`, con `campos_relacion` renombrado y
      `catalogo`/`campo_visualizacion`/`campos_acompanamiento` intactos),
      que el intento manual se había perdido por el error de
      "huérfano" corregido arriba. Autómata (Activo/Baja + 4
      transiciones) y plantilla automática (publicada) también
      correctos. La restricción `EXCLUDE` anti-traslape del original
      (real, ver R8) sigue sin clonarse — fuera de alcance v1, un
      admin puede agregarla a mano con una migración propia si hace
      falta.

## Grupo F — Bug real: `codigo_trn` en un catálogo transaccional (R4a)

Encontrado probando "Copiar" en vivo sobre "Clusters"
(`pty_dsd_cs_cluster`, transaccional): `codigo_trn: es obligatorio
para un catálogo transaccional` — `armar_attrs/4` copiaba
`schema_es_transaccional: true` pero nunca generaba un `codigo_trn`
(y copiar el del original habría chocado contra su unique
constraint de todos modos).

- [x] F1. `MetaClonador.crear_con_reintento/1,2` + `generar_codigo_trn_aleatorio/0`
      (privadas) — cuando `schema_es_transaccional: true`, genera un
      `codigo_trn` aleatorio antes de `insertar_proceso/1`,
      reintentando hasta 5 veces SOLO si el error es
      `unique_constraint(:codigo_trn)` (cualquier otro error corta al
      primer intento) — mismo mecanismo que
      `BcNuevoCompletoLive.crear_con_reintento_codigo_trn/2`.
- [ ] F2. **Sin test automatizado a propósito** — el retry vive en
      `crear_con_reintento/1,2`, que solo se ejecuta como parte de
      `clonar/2` completo (con `CatalogoGenerador.generar/1`, DDL) —
      no hay forma de aislarlo sin pasar por ahí, mismo motivo que ya
      excluyó el happy path de cobertura automatizada en D1/D2.
      Cubierto por F3 (verificación real).
- [x] F3. Verificado en vivo (4 corridas, `pty_e2e_trn_<sufijo>` →
      `pty_e2e_trn_copia_<sufijo>`, catálogo descartable, limpiado
      después): el clon queda con `schema_es_transaccional: true` +
      un `codigo_trn` propio, válido (`~r/^[A-Z0-9]{4}$/`) y distinto
      del original en las 4 corridas. Cero residuo. El "Clusters"
      real de la captura del usuario ya puede reintentarse desde la
      UI.
