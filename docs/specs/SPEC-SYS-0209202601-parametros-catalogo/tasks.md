# SPEC-SYS-0209202601 — Parámetros y Totales para Catálogos (BC)

**Documento:** Tasks · **Fase:** ✅ aprobada (2026-09-02), ejecución en
curso — "aprobado todo", se sigue sin pausar entre grupos salvo bloqueo
real.

Orden pensado para que cada grupo sea verificable antes de enganchar el
siguiente (mismo criterio que la spec de Folios): primero el motor
aislado, después los datos existentes migrados, después la UI de
configuración, recién al final el reemplazo del embudo (el cambio de
mayor riesgo, toca TODOS los catálogos).

## Grupo A — `MetadataApp.ParametrosCatalogo` (motor, aislado) ✅

1. [x] Extraído a [`lib/metadata_app/parametros_catalogo.ex`](../../../lib/metadata_app/parametros_catalogo.ex)
   — `tipo_efectivo/1`, `catalogo_control_sistema/1`, `tipo_elegible?/1`,
   `campos_elegibles_fecha/numerico/string/1`, `clave_campo/1`,
   `campo_atom_real/1` (público — MetaConsultas lo sigue usando fuera del
   motor de Parámetro, en select/totales) y
   `aplicar_filtros_parametro_estandar/4` con toda su cadena interna.
   Firma sobre `campos :: [map()]` y `alias_por_catalogo :: %{String.t()
   => atom()}`, nunca `%Consulta{}`.
2. [x] `MetaConsultas` reducido a adaptador fino — `defdelegate` para las
   funciones sin transformación, wrappers de una línea (`%Consulta{campos:
   campos} -> ParametrosCatalogo.xxx(campos)`) donde hacía falta
   desempaquetar el struct. Los 3 call sites de
   `aplicar_filtros_parametro_estandar` (`query_representativa_con_filtros/1`,
   `contar/5`, `ejecutar/6`) ahora llaman a `ParametrosCatalogo` con
   `consulta.campos`. `aplicar_filtro/4` de bajo nivel (el que usa el
   filtro GENÉRICO de columna, `aplicar_filtros/4`) se dejó DUPLICADO a
   propósito en los dos módulos — sirve a un caller distinto, no vale la
   pena acoplarlo.
3. [x] [`test/metadata_app/parametros_catalogo_test.exs`](../../../test/metadata_app/parametros_catalogo_test.exs)
   (7 tests) — contra `MetaFixtureCliente` (catálogo real) con una query
   armada a mano (`from(r in MetaFixtureCliente, as: :t0, ...)`), CERO
   `%Consulta{}` de por medio — prueba que el motor es de verdad
   agnóstico de origen. Cubre: filtrado de elegibles, `tipo_efectivo`
   para campo de control, string "like", numérico "entre" (acotado),
   `overrides_parametro` pisando el default sin persistir, y "sin
   es_parametro no filtra nada".
4. [x] Regresión: suite completa 471 tests (464 + 7 nuevos), mismos 2
   failures preexistentes sin relación (tar de Windows, campo
   `docker_servicio`) — nada de `MetaConsultas`/Consultas se rompió.

## Grupo B — Migración de datos existentes ✅

5. [x] Script `migrar_parametros_bc.exs` — `meta_schema_detail`: por cada
   fila con `filtro_default_valor`/`_desde`/`_hasta`/`_bloqueado`, arma
   `defaults` unificado + `bloqueado`, borra las claves viejas.
   Idempotente. **Hallazgo real al correrlo**: 0 filas en dev Y en test
   tenían alguna de esas claves — nadie había configurado un default
   todavía (los 3 campos con `agregacion_activa` en `pty_gasto_diariov2`/
   `pty_dsd_empleados_funcion` están en `false`, sin dato que perder). El
   script queda listo y corrido igual, por si producción sí tiene datos
   reales (sin acceso a esa base desde acá — pendiente que alguien lo
   corra ahí también antes/durante el deploy).
6. [x] Script `migrar_totales_consulta.exs` — `meta_schema_consulta.campos`:
   agrega `"bloqueado": false` a toda entrada; `"totalizar"` → shape rico
   (`agregacion_activa` + sub-flags). Corrido en dev y test — la única
   Consulta real que existe (`pty_dsd_cs_clientes`, "Clientes Core", 21
   campos) migrada y verificada por consulta directa a Postgres: todas
   las demás claves (`es_parametro`, `tipo_filtro`, `defaults`, `origen`,
   `catalogo_referenciado`) intactas, `totalizar` reemplazado por
   `agregacion_activa` (ninguna estaba en `true`, cero comportamiento
   real perdido).
7. [x] Verificación manual (psql, antes/después) — ver arriba. Suite
   completa sin failures nuevas (471 tests, mismos 2 preexistentes +
   flakiness ya conocida de TRN bajo concurrencia).

## Grupo C — Componentes UI compartidos ✅

8. [x] Movidos a [`lib/metadata_app_web/parametros_catalogo_components.ex`](../../../lib/metadata_app_web/parametros_catalogo_components.ex):
   `celdas_parametro`, `toggle_es_parametro`, `selector_tipo_filtro`,
   `toggle_acotado`, `defaults_fecha`, `defaults_string`,
   `defaults_numerico`, `origen_string`, `selector_catalogo` (+
   `props_referenciado`/`completar_campos_acompanamiento_sistema`, que ya
   eran agnósticos de origen y quedaron mejor ubicados en
   `ParametrosCatalogo`). **Ajuste real encontrado al mover**: los
   componentes con `<input>`/`<select>` tenían `form="form-guardar-columnas"`
   escrito a mano — un componente de verdad compartido no puede asumir
   el id del form de quien lo usa, así que ahora reciben `form_id` como
   attr. `identificador/1` (id de campo para el DOM, distinto de
   `ParametrosCatalogo.clave_campo/1`) quedó duplicado a propósito —
   `consulta_editor_live.ex` lo sigue usando en sus propios handlers,
   no solo en templates, no valía la pena forzar un import cruzado por
   una función de una línea.
9. [x] Componente nuevo `celda_totales/1` (mismo módulo) — Mín./Máx./Pág./
   Gral. como chips + Máscara con 2 selects, mismo patrón visual que
   `defaults_numerico`. El toggle principal ("Totaliza"/"No totaliza",
   evento `cambiar_agregacion_activa`) es una simplificación deliberada
   del viejo mecanismo de `panel_filtros_resumen` (que agregaba/quitaba
   de una lista aparte vía dropdown+submit) — no entra bien apretado
   adentro de una celda de grilla, un toggle directo es más simple y
   dice lo mismo.
10. [x] `consulta_editor_live.ex` importa `ParametrosCatalogoComponents`
    (`celdas_parametro`/`toggle_es_parametro`) — sus 18 tests de Get
    Config (incluidos los que hacen `render_click` real sobre
    `cambiar_es_parametro`/`cambiar_acotado`) siguen en verde tal cual,
    sin tocar ningún test viejo. Suite completa: 471, mismos 2 failures
    preexistentes.

## Grupo D — Get Config de BC: grilla unificada ✅

11. [x] "Columnas del GET" gana `Vis. | Tot. | Param | Tipo | Acot. |
    Default` (mismo orden que la foto de Consultas), usando
    `ParametrosCatalogoComponents` tal cual. `filas_get_view/2` gana una
    clave nueva por fila, `campo_param` (el `campo["catalogo"]`/
    `campo["campo"]`/... que esos componentes esperan, armado desde
    `schema_context_properties`) — `nil` para filas de control (id/
    estado/trn/...) y para `fecha_registro`, que muestran "—" en las 5
    columnas nuevas (mismo alcance que ya tenía Totales antes).
12. [x] `panel_filtros_resumen` retirado entero — función, call site, Y
    sus 5 handlers ahora muertos (`agregar_filtro_resumen`,
    `quitar_filtro_resumen`, `cambiar_filtro_valor_default`,
    `cambiar_filtro_rango_default`, `cambiar_filtro_bloqueado` — estos
    últimos 3 escribían `filtro_default_*`, ya migrados a `defaults`/
    `bloqueado` en Grupo B).
13. [x] Handlers nuevos: `cambiar_es_parametro`, `cambiar_acotado`,
    `cambiar_tipo_filtro`, `cambiar_origen`, `cambiar_catalogo_referenciado`,
    `cambiar_defaults_modo/valor/valor_hasta/valores`,
    `marcar_defaults_todos`, `limpiar_defaults_valores` (mismos nombres/
    semántica que `consulta_editor_live.ex`, contra `meta_schema_detail`
    vía `actualizar_props_por_id/4`) + `cambiar_agregacion_activa`
    (nuevo, el toggle principal de Totales). `cambiar_minmax_recomendado`/
    `cambiar_total_pagina`/`cambiar_total_general`/`cambiar_mascara` NO
    se tocaron — ya eran de `meta_schema_detail`, `celda_totales/1` les
    manda el mismo evento con el mismo shape de siempre.
    **Detalle real**: el `id` que arma `ParametrosCatalogoComponents.identificador/1`
    es compuesto (`"catalogo::campo"`, pensado para Consultas con N
    tablas) — como un BC es una sola tabla, `campo_desde_id/1` solo
    necesita la mitad después de "::".
14. [x] 3 tests LiveView nuevos
    ([`bc_motor_live_parametros_test.exs`](../../../test/metadata_app_web/live/sysadmin/bc_motor_live_parametros_test.exs)) —
    Param+Tipo+Default en un campo string, Acotado+Default en uno
    numérico, Totales (toggle principal + Mín.Máx + Total general) — los
    tres contra `meta_fixture_cliente` real, verificando
    `meta_schema_detail.schema_context_properties` después de cada
    evento. Suite completa: 474 tests, mismos 2 failures preexistentes +
    la flakiness ya conocida de TRN.

## Grupo E — Consultas: Totales a la par (R4 ampliado) ✅

15. [x] `panel_get_config` (Consultas) — columna `Tot.` pasa del checkbox
    simple (`name="totalizar[]"`) a `<.celda_totales>` (mismo componente
    de BC). 5 handlers nuevos (`cambiar_agregacion_activa` — con defensa
    en profundidad server-side, solo integer/decimal, mismo criterio que
    `toggle_es_parametro/1` con "visible" —, `cambiar_minmax_recomendado`,
    `cambiar_total_pagina`, `cambiar_total_general`, `cambiar_mascara`),
    mismo patrón `mapear_campo/3` + `guardar_campos/3` que ya usan los
    handlers de Parámetro. `guardar_columnas` perdió su rama de
    `"totalizar"` (el checkbox que la alimentaba ya no existe).
16. [x] `MetaConsultas.totales/3` lee `"agregacion_activa"` en vez de
    `"totalizar"`. Los 2 lugares donde nacía un campo nuevo
    (`sincronizar_campos_control/2`, `campos_del_catalogo/2`) arrancan
    con el shape nuevo completo (`agregacion_activa`/`bloqueado`) en vez
    del booleano viejo.
17. [x] Regresión: 6 tests reales rotos al retirar `"totalizar"`
    (`ConsultaControllerTest`, `MetaConsultasTest`,
    `CatalogoLiveConsultaTest`, 3× `ConsultaEditorLiveTest`) — 3 eran
    fixtures con la clave vieja (renombradas a `agregacion_activa`), 3
    testeaban el mecanismo VIEJO (checkbox disabled) y se reescribieron
    para el nuevo (`celda_totales` sin toggle para no-numéricos +
    defensa en profundidad del handler). Suite completa: 474 tests,
    mismos 2 failures preexistentes. Verificado además con un script
    contra dev real (rollback) que Totales suma bien filas reales YA
    existentes (`pty_subtipos_transaccion`, 2 filas que el usuario ya
    había cargado) junto con filas nuevas de la misma corrida — la suma
    total confirmó que el motor las contó a todas correctamente.

## Grupo F — Reemplazo del embudo (el cambio de mayor riesgo) ✅

18. [x] `montar_catalogo/2` (camino BC): `campos_param_de_catalogo/2` arma
    el shape plano (`"catalogo"=>`/`"campo"=>`+props) desde
    `MetaSchemaContext.listar_detalles/1` (excluye `fecha_registro`,
    mismo criterio que `campo_param: nil` de Grupo D en bc_motor_live.ex);
    `parametros_de_consulta/3` se generalizó a `parametros_de_campos/3`
    (recibe `campos` plano, no `%Consulta{}`) y la usan los dos caminos.
    `montar_catalogo/2` gana `parametros_string/numerico/fecha`,
    `overrides_parametro`, `detalles_por_catalogo`, `campos_param`,
    `modos_fecha_rango/simple` — mismos assigns que ya tenía `consulta`.
19. [x] `CatalogoGenerico.listar/6` y `contar/5` ganan un 6°/5° argumento
    opcional `parametros :: nil | {campos_param, alias_por_catalogo,
    overrides_parametro}` (default `nil`, cero cambio de conducta para
    callers existentes — `MetaBcApi`, `CatalogoController`). El `from`
    base gana `as: :t0` (inocuo para bindings posicionales `[r]` ya
    escritos) para que `ParametrosCatalogo.aplicar_filtros_parametro_estandar/4`
    pueda engancharse tal cual (mismo motor que ya usa
    `MetaConsultas.ejecutar/6`, sin reinventar un traductor paralelo).
    `cargar_filas_catalogo/1` arma `{campos_param, %{catalogo => :t0},
    overrides_parametro}` y se lo pasa a los dos.
20. [x] `panel_parametros` se renderiza también en el camino `modulo`
    (mismo componente, sin cambios) — el botón "Filtros" + `panel_filtros`
    se retiraron de los DOS renders (`modulo` y `consulta` — este último
    también lo tenía, embudo Y panel_parametros convivían ahí, contra lo
    que decía el design original).
21. [x] Retirado por completo: `panel_filtros/1`, `filtro_columna/1` (4
    clauses), `fila_filtro_columna/1` (4 clauses), la rama de negocio Y
    la de control-con-embudo de `celda_encabezado/1` (colapsadas a 2
    clauses), `filtro_columna_activo?/2`, `filtro_control_activo?/2`,
    `opciones_para_control/3`, `campos_con_agregacion_activa/1`,
    `filtros_default_desde_columnas/1` (ya obsoleta desde Grupo B),
    `merge_filtros_por_target/1`, `preservar_filtros_bloqueados/2`,
    `campo_bloqueado?/2`, `quitar_valores_filtro/2`,
    `contar_filtros_activos/1`, `columnas_disponibles/3`, el reduce de
    campos de control en `construir_filtros_ecto/2`, y los handlers
    `filtrar`/`limpiar_filtros`/`abrir_filtros`/`cerrar_filtros`/
    `abrir_selector_campo`/`cerrar_selector_campo`/`buscar_campo_filtro`/
    `agregar_filtro_campo`/`quitar_filtro_campo`. **Hallazgo real**: los
    campos de control (Estado/Sucursal/Almacén/Unidad de venta) pierden
    su filtro SIN reemplazo — Grupo D ya había decidido no ofrecerles
    "Parámetro" en Get Config (`campo_param: nil`), así que no hay a
    dónde migrar ese filtro; queda documentado en el código.
    **Bug preexistente encontrado y corregido de paso**: el tfoot viejo
    de "Totales" de una Consulta (`Map.get(columna, :totalizar)`) leía
    una clave que Grupo E ya había renombrado a `"agregacion_activa"` —
    nunca mostraba nada desde Grupo E. Se retiró (celdas_resumen ya
    cubre lo mismo, más rico) y se corrigió `columna_desde_campo_consulta/2`,
    que tampoco copiaba `agregacion_activa`/`total_general_activo`/etc.
    de `consulta.campos` a `schema_context_properties` — la banda de
    Totales de una Consulta nunca había funcionado en runtime, solo en
    Get Config.
22. [x] [`catalogo_live_filtros_test.exs`](../../../test/metadata_app_web/live/catalogo_live_filtros_test.exs)
    reescrito entero (4 tests, el viejo probaba el embudo retirado) — un
    BC sin ningún campo "Parámetro" no muestra el panel; uno marcado
    filtra la tabla real; dos parámetros (texto + rango numérico)
    combinan con AND; limpiar un override lo saca del filtro sin tocar
    el otro. Todos contra `meta_fixture_cliente` real (Postgres, no
    mock). `catalogo_live_consulta_test.exs` también actualizado (3
    tests: el de "monta sin traer datos" y el de referencia ahora marcan
    `es_parametro` a mano, ya no hay embudo implícito; el de Totales usa
    la aserción "Totalizado: 10" en vez del tfoot viejo).

## Grupo G — Cierre

23. [x] Suite completa (`mix test`): 474 tests + 5 properties, 3
    failures — los mismos 2 preexistentes de siempre (tar de Windows,
    `docker_servicio`) + la flakiness ya conocida de TRN bajo
    concurrencia (`IdentificadoresTransaccionalesTest`, no toca ningún
    archivo de este spec). Cero failures nuevos.
24. [ ] Verificación manual (pendiente — necesita ojos humanos/browser):
    abrir un BC real y una Consulta real, confirmar que el Get Config de
    los dos se ve igual, y que filtrar/totalizar funciona en los dos por
    el mismo camino. El servidor dev ya está corriendo
    (`http://localhost:4000`) para que se pueda probar.
25. [x] Este documento actualizado con cada tarea completada.
