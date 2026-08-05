defmodule MetadataApp.Repo.Migrations.AgregarAvatarSeedAUsuario do
  use Ecto.Migration

  def change do
    alter table(:meta_schema_usuario) do
      add :avatar_seed, :string
    end
  end
end
