defmodule MetadataApp.Repo.Migrations.IndicesUnicosEjeVentas do
  use Ecto.Migration

  @moduledoc """
  SPEC-ADN-2209202601, eje Ventas — mismo criterio que
  `20260922233000_indice_unico_parametro_por_perfil.exs` (R6): el
  índice compuesto del generador no alcanza. Acá dos casos:

  - R14: un solo renglón vivo por (encabezado_id, parametro) en
    `pty_config_perfiles_salesu_exc`.
  - R12: una sola asignación viva por `sales_unit` en el MAESTRO
    `pty_config_perfiles_salesu`, sin importar el `perfil` (columna
    sola, no compuesto con `encabezado_id` porque acá no hay
    encabezado — es el maestro mismo).
  """

  def change do
    create unique_index(:pty_config_perfiles_salesu_exc, [:encabezado_id, :pty_config_perfiles_salesu_exc_parametro],
             name: :pty_config_perfiles_salesu_exc_parametro_unico_index,
             where: "delete_guid IS NULL"
           )

    create unique_index(:pty_config_perfiles_salesu, [:pty_config_perfiles_salesu_sales_unit],
             name: :pty_config_perfiles_salesu_sales_unit_unico_index,
             where: "delete_guid IS NULL"
           )
  end
end
