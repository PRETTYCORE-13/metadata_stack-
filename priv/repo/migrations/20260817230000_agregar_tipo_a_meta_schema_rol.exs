defmodule MetadataApp.Repo.Migrations.AgregarTipoAMetaSchemaRol do
  use Ecto.Migration

  # Mismos 10 nombres que Permissions.capacidades_sysadmin/0 -- son los
  # ÚNICOS roles que nacen tipo :sysadmin. Todo lo demás (incluido
  # "administrador", que es es_sistema:true pero un rol de NEGOCIO -- lo
  # ve/gestiona cualquier empresa, no es una pantalla técnica de la
  # plataforma) se queda en el default :negocio.
  @capacidades_sysadmin ~w(
    acceso_sysadmin_bc
    acceso_sysadmin_tepache
    acceso_sysadmin_roles
    acceso_sysadmin_empresas
    acceso_sysadmin_usuarios
    acceso_sysadmin_catalogos_permisos
    acceso_sysadmin_jerarquia
    acceso_sysadmin_credenciales
    acceso_sysadmin_acciones_externas
    acceso_sysadmin_ambientes
  )

  # up/down (no change/0): el backfill con execute/1 necesita la columna
  # ya creada, y alter table queda ENCOLADO por Ecto hasta el próximo
  # flush/0 (mismo motivo que crear_migracion_drop/1 en CatalogoGenerador).
  def up do
    alter table(:meta_schema_rol) do
      add :tipo, :integer, null: false, default: 1
    end

    flush()

    nombres_sql = Enum.map_join(@capacidades_sysadmin, ",", &"'#{&1}'")
    execute("update meta_schema_rol set tipo = 0 where nombre in (#{nombres_sql})")
  end

  def down do
    alter table(:meta_schema_rol) do
      remove :tipo
    end
  end
end
