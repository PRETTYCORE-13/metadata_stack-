defmodule MetadataApp.Repo.Migrations.QuitarIndiceUnicoNegocioPedidos do
  use Ecto.Migration

  # Bug real (2026-09-11): pty_dsd_pedidos_unico_index exigía que TODOS
  # los campos de negocio combinados (empresa+sucursal+almacén+unidad+
  # cliente+rfc+las 3 fechas) fueran únicos entre pedidos -- rechazaba
  # pedidos legítimos con el mismo cliente/sucursal/fecha (caso normal de
  # negocio). pty_dsd_pedidos tiene folio -- su identidad real es el
  # folio/TRN, no la combinación de sus campos. CatalogoGenerador ya no
  # genera este índice para ningún catálogo con requiere_folio: true (ver
  # indice_unico_negocio/4 en catalogo_generador.ex) -- esto solo quita
  # el que ya existía físicamente para este catálogo puntual.
  def change do
    drop_if_exists unique_index(:pty_dsd_pedidos, [
                     :pty_dsd_pedidos_empresa,
                     :pty_dsd_pedidos_branch,
                     :pty_dsd_pedidos_inventory_location,
                     :pty_dsd_pedidos_sales_unit,
                     :pty_dsd_pedidos_dsd_cs_clientes_ope,
                     :pty_dsd_pedidos_dsd_dsd_fac_rfc,
                     :pty_dsd_pedidos_fecha_venta,
                     :pty_dsd_pedidos_fecha_despacho,
                     :pty_dsd_pedidos_fecha_remision
                   ],
                   name: :pty_dsd_pedidos_unico_index
                 )
  end
end
