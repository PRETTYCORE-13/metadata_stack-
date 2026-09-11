defmodule MetadataApp.Repo.Migrations.RegistrarCatalogoPtySubtiposTransaccion do
  use Ecto.Migration

  # Corregido 2026-09-11 (CI real, "Migrar desde base vacía") -- mismo
  # motivo exacto que 20260903000000_registrar_catalogo_pty_folio_perfiles.exs
  # (ver ahí el detalle completo): `MetaSchemaContext.obtener_header_por_nombre/1`
  # arma su SELECT contra el módulo Header COMPILADO HOY (con columnas
  # que en 2026-09-03 todavía no existían, ej. mostrar_folio_en_tabla),
  # así que en una base que arranca de cero (orden cronológico real)
  # esto reventaba con Postgrex.Error 42703. Reescrita 100% en SQL
  # crudo -- header, detalles, estados Y transiciones -- para no
  # depender de NINGÚN módulo Ecto de lib/, solo de las columnas reales
  # de este punto del historial.

  # SPEC-SYS-0109202601 (Administrador de Folios), Grupo F (tasks.md
  # tarea 25) -- `pty_subtipos_transaccion` es un BC real con autómata
  # propio (Activo -> Baja, sin reactivación), pero su registro
  # (meta_schema_header/detail/estados/transiciones -- normalmente vía
  # `mix meta.import` + un .meta.json) nunca se comiteó, mismo motivo que
  # `20260903000000_registrar_catalogo_pty_folio_perfiles.exs` (ver ahí):
  # el .meta.json de un catálogo `pty_*` está gitignorado por convención.
  # `pty_folio_perfiles_subtipos_transaccion` (referencia real desde
  # `pty_folio_perfiles`) y `IdentificadoresTransaccionales.asignar/4`
  # (bloquea el folio si el subtipo está de baja) dependen de que este
  # catálogo exista como BC real en CUALQUIER ambiente, no solo donde
  # alguien lo armó a mano con el Motor BC.
  #
  # Idempotente a propósito, mismo criterio que la migración de
  # pty_folio_perfiles.
  def up do
    %{rows: existentes} =
      repo().query!(
        "SELECT id FROM meta_schema_header WHERE schema_context_name = $1 AND delete_guid IS NULL",
        ["pty_subtipos_transaccion"]
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
             mostrar_inventory_location_en_tabla, mostrar_sales_unit_en_tabla,
             schema_es_transaccional, insert_guid)
          VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15)
          RETURNING id
          """,
          [
            "pty_subtipos_transaccion",
            "Subtipos de Transacción",
            1,
            "/sistema/transacciones/subtipos-transaccion",
            true,
            true,
            true,
            true,
            true,
            true,
            true,
            true,
            true,
            false,
            guid.()
          ]
        )

      detalles = [
        {"tipo_transaccion",
         %{
           "tipo" => "referencia",
           "catalogo" => "meta_schema_header",
           "etiqueta" => "Tipo de transacción",
           "editable" => true,
           "opcional" => false,
           "orden" => 1,
           "visible" => true
         }},
        {"descripcion",
         %{
           "tipo" => "string",
           "longitud" => 255,
           "etiqueta" => "Descripción",
           "editable" => true,
           "opcional" => false,
           "orden" => 2,
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

      %{rows: [[activo_id]]} =
        repo().query!(
          "INSERT INTO meta_schema_estados (meta_schema_header_id, nombre, orden, es_inicial, insert_guid) VALUES ($1, $2, $3, $4, $5) RETURNING id",
          [header_id, "Activo", 1, true, guid.()]
        )

      %{rows: [[baja_id]]} =
        repo().query!(
          "INSERT INTO meta_schema_estados (meta_schema_header_id, nombre, orden, es_inicial, insert_guid) VALUES ($1, $2, $3, $4, $5) RETURNING id",
          [header_id, "Baja", 2, false, guid.()]
        )

      repo().query!(
        """
        INSERT INTO meta_schema_transiciones
          (meta_schema_header_id, accion, etiqueta, estado_origen_id, estado_destino_id, campos_editables, insert_guid)
        VALUES ($1, $2, $3, $4, $5, $6::varchar[], $7)
        """,
        [header_id, "alta", "Alta", nil, activo_id, ["tipo_transaccion", "descripcion"], guid.()]
      )

      repo().query!(
        """
        INSERT INTO meta_schema_transiciones
          (meta_schema_header_id, accion, etiqueta, estado_origen_id, estado_destino_id, campos_editables, insert_guid)
        VALUES ($1, $2, $3, $4, $5, $6::varchar[], $7)
        """,
        [header_id, "baja", "Dar de baja", activo_id, baja_id, [], guid.()]
      )
    end
  end

  def down do
    :ok
  end
end
