defmodule MetadataApp.Repo.Migrations.AgregarSuperAdminYSeedSysadmin do
  use Ecto.Migration

  # super_admin: cross-empresa, fuera del RBAC normal (que siempre gira
  # alrededor de una empresa activa) — ver comentario en
  # MetadataApp.Autenticacion.Usuario. Solo el esquema acá — el alta del
  # usuario SYSADMIN en sí YA NO se siembra en una migración (un email/
  # password fijo quedaría en git para siempre, visible a cualquiera con
  # acceso al repo). Ver MetadataApp.Release.seed_sysadmin/0: lee
  # SYSADMIN_EMAIL/SYSADMIN_PASSWORD del entorno de cada despliegue —
  # mismo criterio que usa Oracle (SYS/SYSTEM son nombres fijos, pero la
  # contraseña se define en el momento de crear la instancia, nunca viene
  # de fábrica).
  def up do
    alter table(:meta_schema_usuario) do
      add :super_admin, :boolean, default: false, null: false
    end
  end

  def down do
    alter table(:meta_schema_usuario) do
      remove :super_admin
    end
  end
end
