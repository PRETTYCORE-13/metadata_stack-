defmodule MetadataApp.Repo.Migrations.AgregarFechaRegistroAMetaFixtureClienteEquipo do
  use Ecto.Migration

  # La reconstrucción de arriba (20260910191000) ya salió aplicada en dev
  # y test SIN esta columna -- se agregó recién acá para no editar una
  # migración ya corrida (Ecto no la vuelve a correr por versión). Mismo
  # patrón que 20260813130000_agregar_fecha_registro_a_meta_fixture_alcance.exs.
  def change do
    alter table(:meta_fixture_cliente) do
      add_if_not_exists :fecha_registro, :utc_datetime, null: true
    end

    alter table(:meta_fixture_equipo) do
      add_if_not_exists :fecha_registro, :utc_datetime, null: true
    end
  end
end
