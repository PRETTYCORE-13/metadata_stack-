defmodule MetadataApp.Repo.Migrations.AgregarPtyClientesFechaBajaAPtyClientes20260708000708941 do
  use Ecto.Migration

  def change do
    alter table(:pty_clientes) do
      add :pty_clientes_fecha_baja, :date, null: true
    end
  end
end
