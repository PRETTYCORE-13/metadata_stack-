defmodule MetadataApp.Repo.Migrations.SeedPermisoCapacidadSysadminPurgar do
  use Ecto.Migration

  # Pantalla "Purgar" (SPEC-ARQ-3009202601, R1) -- mismo patrón que
  # 20260918131209 (Propagación), pero con tipo = 0 (sysadmin) explícito:
  # el default de la columna es 1 (negocio).
  def up do
    {1, [%{id: permiso_id}]} =
      repo().insert_all(
        "meta_schema_permiso",
        [
          %{
            recurso: "sysadmin_purgar",
            accion: "leer",
            descripcion: "Acceso a Purgar artefactos (Sysadmin)",
            insert_guid: guid()
          }
        ],
        returning: [:id]
      )

    {1, [%{id: rol_id}]} =
      repo().insert_all(
        "meta_schema_rol",
        [
          %{
            empresa_id: nil,
            nombre: "acceso_sysadmin_purgar",
            descripcion: "Acceso a Purgar artefactos (Sysadmin)",
            es_sistema: true,
            tipo: 0,
            insert_guid: guid()
          }
        ],
        returning: [:id]
      )

    repo().insert_all("meta_schema_rol_permiso", [
      %{rol_id: rol_id, permiso_id: permiso_id, insert_guid: guid()}
    ])
  end

  defp guid, do: Ecto.UUID.generate() |> String.replace("-", "")

  def down do
    execute(
      "DELETE FROM meta_schema_rol WHERE nombre = 'acceso_sysadmin_purgar' AND es_sistema = true"
    )

    execute("DELETE FROM meta_schema_permiso WHERE recurso = 'sysadmin_purgar'")
  end
end
