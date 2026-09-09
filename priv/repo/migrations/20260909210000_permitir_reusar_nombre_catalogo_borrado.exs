defmodule MetadataApp.Repo.Migrations.PermitirReusarNombreCatalogoBorrado do
  use Ecto.Migration

  # Encontrado en vivo (2026-09-09): `pty_dsd_pedidos` se había marcado
  # borrado (delete_guid) porque su tabla física ya no existía, pero el
  # índice único de `schema_context_name` NUNCA filtraba por
  # `delete_guid IS NULL` -- a diferencia de CASI TODO el resto de este
  # esquema (`meta_schema_detail_unico_index`, `meta_schema_rol_nombre_
  # unico_index`, `meta_schema_ambiente_deploy_nombre_index`, etc., todos
  # con el mismo `WHERE delete_guid IS NULL`). Resultado: intentar dar de
  # alta un catálogo nuevo con ese mismo nombre fallaba con "ya existe"
  # (`unique_constraint`), aunque BC List (que sí filtra por delete_guid
  # IS NULL) no lo mostrara para nada -- el nombre quedaba bloqueado para
  # siempre sin ninguna fila viva usándolo. Mismo bug, mismo fix, que ya
  # se corrigió para roles en 20260901234500_unificar_nombre_rol_global.exs.
  def change do
    drop unique_index(:meta_schema_header, [:schema_context_name],
           name: :meta_schema_header_schema_context_name_index
         )

    create unique_index(:meta_schema_header, [:schema_context_name],
             name: :meta_schema_header_schema_context_name_unico_index,
             where: "delete_guid IS NULL"
           )
  end
end
