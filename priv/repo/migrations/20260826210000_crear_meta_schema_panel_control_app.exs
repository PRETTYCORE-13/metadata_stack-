defmodule MetadataApp.Repo.Migrations.CrearMetaSchemaPanelControlApp do
  use Ecto.Migration

  # "Panel Control" (Sysadmin, 2026-08-26) -- levantar una app nueva
  # (dominio + deploy) sobre k3s, para cualquier imagen Docker. Nada
  # cifrado en esta tabla a propósito: las credenciales SSH (para llegar
  # al servidor y correr kubectl) y el token de Hostinger (para el DNS) ya
  # viven en meta_schema_ambiente_deploy/meta_schema_credencial -- esta
  # tabla solo registra QUÉ se pidió desplegar y en qué quedó
  # (nodeport/estado/ultimo_error, que Desplegador.crear_app/1 va
  # actualizando a medida que avanza).
  def change do
    create table(:meta_schema_panel_control_app) do
      add :nombre, :string, null: false
      add :subdominio, :string, null: false
      add :dominio_base, :string, null: false
      add :imagen_docker, :string, null: false
      add :puerto_interno, :integer, null: false
      add :variables_entorno, :map, null: false, default: %{}
      add :nodeport, :integer
      add :estado, :string, null: false, default: "pendiente"
      add :ultimo_error, :string

      add :ambiente_id, references(:meta_schema_ambiente_deploy), null: false

      add :insert_guid, :string
      add :update_guid, :string
      add :delete_guid, :string

      timestamps(type: :utc_datetime)
    end

    create unique_index(:meta_schema_panel_control_app, [:subdominio, :dominio_base], where: "delete_guid IS NULL")
    create index(:meta_schema_panel_control_app, [:ambiente_id])
    create index(:meta_schema_panel_control_app, [:delete_guid])
  end
end
