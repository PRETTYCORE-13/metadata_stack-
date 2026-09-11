defmodule MetadataApp.Repo.Migrations.RegistrarCatalogoPtyFolioPerfiles do
  use Ecto.Migration

  # Corregido 2026-09-11 (CI real, "Migrar desde base vacía"): la versión
  # original de esta migración llamaba a
  # MetadataApp.BusinessProcessBuilder.MetaSchemaContext.obtener_header_por_nombre/1
  # y crear_header_con_detalles/1 -- funciones que arman su query contra
  # el módulo Header COMPILADO HOY, con TODAS sus columnas actuales
  # (ej. mostrar_folio_en_tabla, agregada recién por la migración
  # 20260910040000, muy posterior a esta). En una base que arranca de
  # cero, Ecto corre las migraciones en orden cronológico real -- acá
  # esa columna todavía no existe, y el SELECT generado por el struct
  # de hoy revienta con "column ... does not exist"
  # (Postgrex.Error 42703). Reescrita con SQL crudo (repo().query!/2),
  # nombrando solo las columnas que existían en este punto real del
  # historial -- mismo criterio que ya usan
  # 20260727194501_restaurar_metadata_fixtures_de_test.exs y
  # 20260910191000_reconstruir_meta_fixture_cliente_equipo.exs para
  # cualquier INSERT directo sobre meta_schema_header/meta_schema_detail.
  # Ninguna migración de aplicación (a diferencia de código en
  # lib/, que SIEMPRE corre contra el schema de hoy) puede confiar en el
  # módulo Ecto vigente -- solo en el estado real de la base en su propio
  # punto de la secuencia.

  # SPEC-SYS-0109202601 (Administrador de Folios), Grupo B (design.md §6) --
  # `pty_folio_perfiles` se administra como BC real del motor de catálogos
  # (Get/Post estándar, permisos, Ficha), pero su registro
  # (meta_schema_header/meta_schema_detail -- normalmente vía
  # `mix meta.import` + un .meta.json) nunca se comiteó: el .meta.json de
  # un catálogo `pty_*` está gitignorado por convención (nunca va al repo
  # compartido, se regenera por desarrollador). A diferencia del resto de
  # los `pty_*`, ESTE catálogo es dependencia dura de un motor
  # siempre-presente (`MetadataApp.IdentificadoresTransaccionales`), no un
  # catálogo opcional publicado por su cuenta -- sin este registro, un
  # checkout limpio (CI, servidor nuevo) tiene la TABLA pty_folio_perfiles
  # (creada por la migración `20260901201822`) pero el motor no la
  # reconoce como catálogo real (`Ecto.NoResultsError` buscando el header
  # en `MetaStateEngine.transicion_alta/1`).
  #
  # Idempotente a propósito: en dev/producción donde el catálogo ya se
  # armó a mano (vía el Motor BC, con su propio .meta.json local nunca
  # comiteado) esto es un no-op -- el objetivo es que un ambiente NUEVO
  # arranque igual de funcional, no duplicar el registro donde ya existe.
  #
  # Sin `campos_acompanamiento`/`campo_visualizacion` en los 2 campos
  # `referencia` (mismo gap ya documentado en tasks.md de esta spec,
  # Grupo B tarea 6): `validar_campos_acompanamiento/1` solo conoce
  # catálogos BPB reales vía `meta_schema_detail`, no catálogos de sistema
  # (`meta_schema_header`) ni, acá, un catálogo que podría no estar
  # registrado todavía (`pty_subtipos_transaccion`, su propio registro
  # queda fuera de alcance de este fix) -- cae al fallback "#id", igual
  # que ya pasa en dev/producción.
  def up do
    %{rows: existentes} =
      repo().query!(
        "SELECT id FROM meta_schema_header WHERE schema_context_name = $1 AND delete_guid IS NULL",
        ["pty_folio_perfiles"]
      )

    if existentes == [] do
      guid = fn -> Ecto.UUID.generate() |> String.replace("-", "") end

      %{rows: [[header_id]]} =
        repo().query!(
          """
          INSERT INTO meta_schema_header
            (schema_context_name, schema_context_label, schema_context_type, schema_context_nav,
             schema_visible, cargar_todos_por_default, mostrar_id_en_tabla, mostrar_estado_en_tabla,
             mostrar_trn_en_tabla, mostrar_empresa_en_tabla, mostrar_branch_en_tabla,
             mostrar_inventory_location_en_tabla, mostrar_sales_unit_en_tabla, alcance_habilitado,
             schema_es_transaccional, insert_guid)
          VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, $16)
          RETURNING id
          """,
          [
            "pty_folio_perfiles",
            "Perfiles de Folio",
            1,
            "/sistema/transacciones/folio-perfiles",
            true,
            true,
            false,
            false,
            false,
            false,
            false,
            false,
            false,
            true,
            false,
            guid.()
          ]
        )

      detalles = [
        {"documento",
         %{
           "tipo" => "referencia",
           "catalogo" => "meta_schema_header",
           "etiqueta" => "Tipo de transacción",
           "editable" => true,
           "opcional" => false,
           "orden" => 1,
           "visible" => true
         }},
        {"sucursal",
         %{
           "tipo" => "referencia",
           "catalogo" => "meta_schema_branch",
           "etiqueta" => "Sucursal",
           "editable" => true,
           "opcional" => true,
           "orden" => 2,
           "visible" => true
         }},
        {"serie",
         %{
           "tipo" => "string",
           "longitud" => 4,
           "etiqueta" => "Serie",
           "editable" => true,
           "opcional" => false,
           "orden" => 3,
           "visible" => true
         }},
        {"numero_inicial",
         %{
           "tipo" => "integer",
           "etiqueta" => "Número inicial",
           "editable" => true,
           "opcional" => true,
           "valor_default" => "1",
           "orden" => 4,
           "visible" => true
         }},
        {"pty_folio_perfiles_subtipos_transaccion",
         %{
           "tipo" => "referencia",
           "catalogo" => "pty_subtipos_transaccion",
           "etiqueta" => "Subtipo",
           "editable" => true,
           "opcional" => true,
           "orden" => 5,
           "visible" => true
         }}
      ]

      Enum.each(detalles, fn {campo, props} ->
        repo().query!(
          """
          INSERT INTO meta_schema_detail
            (meta_schema_header_id, schema_context_field, schema_context_properties, insert_guid)
          VALUES ($1, $2, $3::jsonb, $4)
          """,
          [header_id, campo, props, guid.()]
        )
      end)
    end

    # `numero_actual` (design.md §6, tasks.md tarea 7): columna física
    # agregada a mano DESPUÉS de que el catálogo ya existía, fuera de
    # `@campos` (el generado Ficha/CRUD nunca la ve -- solo el motor de
    # IdentificadoresTransaccionales, vía su propio schema Ecto liviano
    # sobre la misma tabla, FolioPerfil). No forma parte de ninguna
    # migración comiteada existente -- `IF NOT EXISTS` la deja idempotente
    # igual que el registro del catálogo arriba.
    execute("ALTER TABLE pty_folio_perfiles ADD COLUMN IF NOT EXISTS numero_actual integer NOT NULL DEFAULT 0")
  end

  def down do
    :ok
  end
end
