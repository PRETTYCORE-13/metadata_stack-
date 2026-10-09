defmodule MetadataApp.Repo.Migrations.EliminarConsultaCroacMasterdataClientesBaseclientes20261006174910 do
  use Ecto.Migration

  def up do
    drop_if_exists table(:consulta_croac_masterdata_clientes_baseclientes)
    # flush/0 obligatorio acá: drop_if_exists (como create/alter) queda
    # ENCOLADO por Ecto, no se ejecuta hasta el final de la migración
    # (o hasta el próximo flush) -- sin esto, purgar_metadata_por_nombre
    # (llamada Elixir normal, corre en el acto) se ejecuta con la tabla
    # todavía física, mismo error de FK que si nunca se hubiera reordenado.
    flush()
    MetadataApp.BusinessProcessBuilder.CatalogoGenerador.purgar_metadata_por_nombre("consulta_croac_masterdata_clientes_baseclientes")
  end

  def down do
    :ok
  end
end
