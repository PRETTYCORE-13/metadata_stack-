defmodule MetadataApp.Repo.Migrations.CrearCatalogos do
  use Ecto.Migration

  def change do
    create table(:catalogos) do
      add :tabla, :string, size: 63, null: false
      add :schema_nombre, :string, size: 63, null: false
      add :modulo, :string, size: 63, null: false

      add :insert_guid, :string, size: 32, null: false
      add :update_guid, :string, size: 32, null: true
      add :delete_guid, :string, size: 32, null: true
    end

    create unique_index(:catalogos, [:tabla])
    create unique_index(:catalogos, [:schema_nombre])

    execute(
      """
      INSERT INTO catalogos (tabla, schema_nombre, modulo, insert_guid)
      VALUES
        ('pty_marcas', 'pty_marca', 'PtyMarca', '00000000000000000000000000000001'),
        ('pty_motos', 'pty_motos', 'PtyMotos', '00000000000000000000000000000002')
      """,
      "DELETE FROM catalogos WHERE tabla IN ('pty_marcas', 'pty_motos')"
    )
  end
end
