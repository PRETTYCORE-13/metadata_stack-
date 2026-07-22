defmodule MetadataApp.Repo.Migrations.CrearPtyPedidoDet20260722194025410 do
  use Ecto.Migration

  def change do
    create table(:pty_pedido_det) do
      add :pty_pedidodet_producto, :string, size: 15, null: false
      add :pty_pedidodet_cantidad, :integer, null: false
      add :pty_pedidodet_precio, :decimal, precision: 20, scale: 2, null: false

      add :insert_guid, :string, size: 32, null: false
      add :update_guid, :string, size: 32, null: true
      add :delete_guid, :string, size: 32, null: true

      add :estado_id, references(:meta_schema_estados), null: true

      add :encabezado_id, references(:pty_pedido_enc), null: false
      add :renglon_id, :integer, null: false

    end

    create unique_index(:pty_pedido_det, [:pty_pedidodet_producto, :pty_pedidodet_cantidad, :pty_pedidodet_precio], name: :pty_pedido_det_unico_index)
    create unique_index(:pty_pedido_det, [:encabezado_id, :renglon_id], name: :pty_pedido_det_encabezado_renglon_unico_index)

  end
end
