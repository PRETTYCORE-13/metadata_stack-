defmodule MetadataApp.Repo.Migrations.UnificarNombreRolGlobal do
  use Ecto.Migration

  # Incidente 2026-09-01: un rol de sistema (es_sistema: true, empresa_id:
  # nil) se creó a mano con el mismo `nombre` que un rol de empresa ya
  # existente ("pty-funcional-admin") -- el índice único de entonces
  # (:meta_schema_rol_sistema_unico_index, solo entre roles de sistema
  # entre sí) no lo evitaba, porque el que colisionó era un rol de
  # EMPRESA. A pedido explícito: `nombre` pasa a ser único en TODA la
  # tabla, sin importar empresa_id/es_sistema -- verificado antes de
  # escribir esto que ninguna fila VIVA colisiona hoy (ninguna empresa
  # reusa el nombre de otra, tampoco con ningún rol de sistema). Sí
  # apareció una colisión real con una fila ya borrada (soft-delete,
  # "pty_registros") -- por eso el índice va con `WHERE delete_guid IS
  # NULL`: un nombre libera su lugar una vez que el rol que lo tenía se
  # da de baja.
  def change do
    drop unique_index(:meta_schema_rol, [:nombre],
           name: :meta_schema_rol_sistema_unico_index,
           where: "empresa_id IS NULL"
         )

    create unique_index(:meta_schema_rol, [:nombre],
             name: :meta_schema_rol_nombre_unico_index,
             where: "delete_guid IS NULL"
           )
  end
end
