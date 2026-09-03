defmodule MetadataApp.Repo.Migrations.RegistrarCatalogoPtySubtiposTransaccion do
  use Ecto.Migration

  alias MetadataApp.BusinessProcessBuilder.MetaSchemaContext
  alias MetadataApp.MetaEstadosAdmin

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
    if MetaSchemaContext.obtener_header_por_nombre("pty_subtipos_transaccion") == nil do
      {:ok, _} =
        MetaEstadosAdmin.crear_proceso_completo(%{
          "header" => %{
            "schema_context_name" => "pty_subtipos_transaccion",
            "schema_context_label" => "Subtipos de Transacción",
            "schema_context_type" => 1,
            "schema_context_nav" => "/sistema/transacciones/subtipos-transaccion",
            "schema_context_icono" => nil,
            "schema_visible" => true,
            "schema_set_permissions" => nil,
            "schema_profiles" => nil,
            "cargar_todos_por_default" => true,
            "mostrar_id_en_tabla" => true,
            "mostrar_estado_en_tabla" => true,
            "mostrar_trn_en_tabla" => true,
            "mostrar_empresa_en_tabla" => true,
            "mostrar_branch_en_tabla" => true,
            "mostrar_inventory_location_en_tabla" => true,
            "mostrar_sales_unit_en_tabla" => true,
            "schema_es_transaccional" => false,
            "codigo_trn" => nil,
            "schema_encabezado_catalogo" => nil,
            "detalles" => [
              %{
                "schema_context_field" => "tipo_transaccion",
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
                "schema_context_field" => "descripcion",
                "schema_context_properties" => %{
                  "tipo" => "string",
                  "longitud" => 255,
                  "etiqueta" => "Descripción",
                  "editable" => true,
                  "opcional" => false,
                  "orden" => 2,
                  "visible" => true
                }
              }
            ]
          },
          "estados" => [
            %{"nombre" => "Activo", "orden" => 1, "es_inicial" => true},
            %{"nombre" => "Baja", "orden" => 2, "es_inicial" => false}
          ],
          "transiciones" => [
            %{
              "accion" => "alta",
              "etiqueta" => "Alta",
              "estado_origen" => nil,
              "estado_destino" => "Activo",
              "campos_editables" => ["tipo_transaccion", "descripcion"]
            },
            %{
              "accion" => "baja",
              "etiqueta" => "Dar de baja",
              "estado_origen" => "Activo",
              "estado_destino" => "Baja",
              "campos_editables" => []
            }
          ]
        })
    end
  end

  def down do
    :ok
  end
end
