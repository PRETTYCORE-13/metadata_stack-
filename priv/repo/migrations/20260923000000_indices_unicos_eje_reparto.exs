defmodule MetadataApp.Repo.Migrations.IndicesUnicosEjeReparto do
  use Ecto.Migration

  @moduledoc """
  SPEC-ADN-2209202601, eje Reparto — espejo de
  `20260922234500_indices_unicos_eje_ventas.exs`:

  - R14: un solo renglón vivo por (encabezado_id, parametro) en
    `pty_config_perfiles_invlocation_exc`.
  - R12: una sola asignación viva por `inventory_location` en el
    MAESTRO `pty_config_perfiles_invlocation`.
  """

  def change do
    create unique_index(:pty_config_perfiles_invlocation_exc, [:encabezado_id, :pty_config_perfiles_invlocation_exc_parametro],
             name: :pty_config_perfiles_invlocation_exc_parametro_unico_index,
             where: "delete_guid IS NULL"
           )

    create unique_index(:pty_config_perfiles_invlocation, [:pty_config_perfiles_invlocation_inventory_location],
             name: :pty_config_perfiles_invlocation_invloc_unico_index,
             where: "delete_guid IS NULL"
           )
  end
end
