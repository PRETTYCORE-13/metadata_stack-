defmodule MetadataApp.Repo.Migrations.BackfillPermisosTransicionesReales do
  use Ecto.Migration

  # El motor de estados ahora exige permiso automático por transición (ver
  # MetaStateEngine.verificar_permiso_transicion/3, 2026-07-26) — sin este
  # backfill, "guardar" y el resto de las transiciones YA EN USO en los
  # catálogos reales quedarían bloqueadas para todo el mundo hasta que
  # alguien las diera de alta a mano una por una. A diferencia de
  # sysadmin_bc/rbac_admin (conjunto fijo del core), esto es un backfill
  # puntual de lo que existe HOY — las transiciones de catálogos nuevos que
  # se agreguen de acá en más se dan de alta a mano (o desde la UI de
  # Roles y Permisos, que ahora también lista transiciones por catálogo).
  @pares [
    {"pty_crm_empresa", "alta"},
    {"pty_crm_empresa", "baja"},
    {"pty_crm_empresa", "guardar"},
    {"pty_crm_empresa", "reactivar"},
    {"pty_crm_segmento", "alta"},
    {"pty_crm_segmento", "guardar"},
    {"pty_crm_comando_enc", "alta"},
    {"pty_crm_comando_enc", "guardar"},
    {"pty_crm_comando_enc", "baja"},
    {"pty_crm_comando_enc", "reactivar"}
  ]

  def up do
    for {recurso, accion} <- @pares do
      repo().insert_all("meta_schema_permiso", [
        %{
          recurso: recurso,
          accion: accion,
          insert_guid: Ecto.UUID.generate() |> String.replace("-", "")
        }
      ])
    end
  end

  def down do
    for {recurso, accion} <- @pares do
      execute "DELETE FROM meta_schema_permiso WHERE recurso = '#{recurso}' AND accion = '#{accion}'"
    end
  end
end
