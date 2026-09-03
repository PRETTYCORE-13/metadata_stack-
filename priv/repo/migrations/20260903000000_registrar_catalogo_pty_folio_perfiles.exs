defmodule MetadataApp.Repo.Migrations.RegistrarCatalogoPtyFolioPerfiles do
  use Ecto.Migration

  alias MetadataApp.BusinessProcessBuilder.MetaSchemaContext

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
    if MetaSchemaContext.obtener_header_por_nombre("pty_folio_perfiles") == nil do
      {:ok, _} =
        MetaSchemaContext.crear_header_con_detalles(%{
          "schema_context_name" => "pty_folio_perfiles",
          "schema_context_label" => "Perfiles de Folio",
          "schema_context_type" => 1,
          "schema_context_nav" => "/sistema/transacciones/folio-perfiles",
          "schema_context_icono" => nil,
          "schema_visible" => true,
          "schema_set_permissions" => nil,
          "schema_profiles" => nil,
          "cargar_todos_por_default" => true,
          "mostrar_id_en_tabla" => false,
          "mostrar_estado_en_tabla" => false,
          "mostrar_trn_en_tabla" => false,
          "mostrar_empresa_en_tabla" => false,
          "mostrar_branch_en_tabla" => false,
          "mostrar_inventory_location_en_tabla" => false,
          "mostrar_sales_unit_en_tabla" => false,
          "alcance_habilitado" => true,
          "schema_es_transaccional" => false,
          "codigo_trn" => nil,
          "schema_encabezado_catalogo" => nil,
          "detalles" => [
            %{
              "schema_context_field" => "documento",
              "schema_context_properties" => %{
                "tipo" => "referencia",
                "catalogo" => "meta_schema_header",
                "etiqueta" => "Tipo de transacción",
                "editable" => true,
                "opcional" => false,
                "orden" => 1,
                "visible" => true
              }
            },
            %{
              "schema_context_field" => "sucursal",
              "schema_context_properties" => %{
                "tipo" => "referencia",
                "catalogo" => "meta_schema_branch",
                "etiqueta" => "Sucursal",
                "editable" => true,
                "opcional" => true,
                "orden" => 2,
                "visible" => true
              }
            },
            %{
              "schema_context_field" => "serie",
              "schema_context_properties" => %{
                "tipo" => "string",
                "longitud" => 4,
                "etiqueta" => "Serie",
                "editable" => true,
                "opcional" => false,
                "orden" => 3,
                "visible" => true
              }
            },
            %{
              "schema_context_field" => "numero_inicial",
              "schema_context_properties" => %{
                "tipo" => "integer",
                "etiqueta" => "Número inicial",
                "editable" => true,
                "opcional" => true,
                "valor_default" => "1",
                "orden" => 4,
                "visible" => true
              }
            },
            %{
              "schema_context_field" => "pty_folio_perfiles_subtipos_transaccion",
              "schema_context_properties" => %{
                "tipo" => "referencia",
                "catalogo" => "pty_subtipos_transaccion",
                "etiqueta" => "Subtipo",
                "editable" => true,
                "opcional" => true,
                "orden" => 5,
                "visible" => true
              }
            }
          ]
        })
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
