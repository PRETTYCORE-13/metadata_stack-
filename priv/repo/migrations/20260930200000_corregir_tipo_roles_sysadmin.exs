defmodule MetadataApp.Repo.Migrations.CorregirTipoRolesSysadmin do
  use Ecto.Migration

  # 20260817230000 marcó tipo = 0 (sysadmin) solo a los 10 roles
  # "acceso_sysadmin_*" que existían entonces. Los sembrados después
  # (20260826210100, 20260917180000, 20260918131209) no indicaron el
  # tipo y quedaron en el default 1 (negocio), así que RolesLive los
  # mostraba como roles de negocio.
  @roles ~w(acceso_sysadmin_panel_control acceso_sysadmin_endpoints acceso_sysadmin_propagacion)

  def up, do: actualizar_tipo(0)

  def down, do: actualizar_tipo(1)

  defp actualizar_tipo(tipo) do
    nombres_sql = Enum.map_join(@roles, ",", &"'#{&1}'")

    execute(
      "UPDATE meta_schema_rol SET tipo = #{tipo} WHERE es_sistema = true AND nombre IN (#{nombres_sql})"
    )
  end
end
