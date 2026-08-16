defmodule MetadataApp.Repo.Migrations.CrearMetaSchemaAmbienteDeploy do
  use Ecto.Migration

  # UI/ambientes-deploy (2026-08-16, a pedido explícito): hoy el servidor
  # de deploy está hardcodeado -- 3 secrets fijos del repo (DEPLOY_HOST/
  # DEPLOY_USER/DEPLOY_SSH_KEY, ver .github/workflows/ci.yml y
  # bc-deploy.yml) apuntan siempre al mismo Docker Swarm. gh workflow run
  # (lo que dispara mix motor.publicar) no puede pasar secrets como input
  # -- solo strings planos -- así que elegir servidor en tiempo de deploy
  # no puede resolverse adentro de esos workflows sin GitHub Environments
  # (que requieren alta manual en la UI de GitHub, fuera del alcance de
  # esta app). En cambio: esta tabla guarda credenciales SSH por ambiente
  # (mismo patrón que meta_schema_credencial/MetadataApp.Encriptado -- ver
  # esa migración) y `mix motor.desplegar <ambiente>` (nuevo, separado de
  # motor.publicar) hace el paso SSH DIRECTO desde la máquina del
  # desarrollador con las credenciales de la fila elegida, en vez de
  # depender de un secret fijo de GitHub.
  #
  # ssh_password/ssh_llave_privada son :binary (no :string) -- igual que
  # api_key en meta_schema_credencial, Cloak.Ecto.Binary guarda el
  # ciphertext ahí, nunca texto plano en ninguna columna. Los dos son
  # opcionales -- un ambiente puede autenticar con clave o con
  # contraseña, mix motor.desplegar prueba clave primero si está.
  def change do
    create table(:meta_schema_ambiente_deploy) do
      add :nombre, :string, null: false
      add :host, :string, null: false
      add :ssh_usuario, :string, null: false
      add :ssh_password, :binary
      add :ssh_llave_privada, :binary
      add :docker_servicio, :string, null: false, default: "metadata_stack_app"
      add :imagen_docker, :string, null: false, default: "ghcr.io/prettycore-13/metadata_stack:latest"

      add :insert_guid, :string
      add :update_guid, :string
      add :delete_guid, :string

      timestamps(type: :utc_datetime)
    end

    create unique_index(:meta_schema_ambiente_deploy, [:nombre], where: "delete_guid IS NULL")
    create index(:meta_schema_ambiente_deploy, [:delete_guid])
  end
end
