defmodule MetadataApp.Repo.Migrations.CrearPtyPedidoEnc20260722193739220 do
  use Ecto.Migration

  def change do
    create table(:pty_pedido_enc) do
      add :pty_pedidoenc_sucursal, :string, size: 4, null: false
      add :pty_pedidoenc_cliente, :string, size: 60, null: false
      add :pty_pedidoenc_fecha, :date, null: false

      add :insert_guid, :string, size: 32, null: false
      add :update_guid, :string, size: 32, null: true
      add :delete_guid, :string, size: 32, null: true

      add :estado_id, references(:meta_schema_estados), null: true

      add :trn, :string, size: 23, null: true
      add :ulid, :string, size: 26, null: true

    end

    create unique_index(:pty_pedido_enc, [:pty_pedidoenc_sucursal, :pty_pedidoenc_cliente, :pty_pedidoenc_fecha], name: :pty_pedido_enc_unico_index)
    create unique_index(:pty_pedido_enc, [:trn], name: :pty_pedido_enc_trn_unico_index)
    create unique_index(:pty_pedido_enc, [:ulid], name: :pty_pedido_enc_ulid_unico_index)

  end
end
