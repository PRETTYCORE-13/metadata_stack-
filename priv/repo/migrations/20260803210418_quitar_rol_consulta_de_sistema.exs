defmodule MetadataApp.Repo.Migrations.QuitarRolConsultaDeSistema do
  use Ecto.Migration

  # Decisión explícita del usuario: solo "administrador" se maneja como rol
  # de sistema de acá en más — "consulta" (sembrado en
  # 20260725010001_seed_roles_sistema.exs) nunca tuvo usuarios asignados
  # (verificado antes de este cambio) y generaba confusión al no poder
  # borrarse/editarse como cualquier otro rol. Soft-delete (no un DELETE
  # físico) — mismo criterio que Permissions.eliminar_rol/1 para
  # cualquier otro rol, y evita arrastrar en cascada los vínculos de
  # meta_schema_rol_permiso que ya tuviera.
  def up do
    execute("""
    UPDATE meta_schema_rol
    SET delete_guid = md5(random()::text || clock_timestamp()::text)
    WHERE nombre = 'consulta' AND es_sistema = true AND empresa_id IS NULL AND delete_guid IS NULL
    """)
  end

  def down do
    execute("""
    UPDATE meta_schema_rol
    SET delete_guid = NULL
    WHERE nombre = 'consulta' AND es_sistema = true AND empresa_id IS NULL
    """)
  end
end
