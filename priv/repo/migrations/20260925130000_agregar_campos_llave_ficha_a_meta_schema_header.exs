defmodule MetadataApp.Repo.Migrations.AgregarCamposLlaveFichaAMetaSchemaHeader do
  use Ecto.Migration

  # "Llave de identificación" de la Ficha 360° (2026-09-25, a pedido
  # explícito -- el usuario primero pidió mostrar los campos del índice
  # único de negocio junto al título, después "que solo sean tres campos
  # y un lugar para seleccionar cuáles aparecerán"): reemplaza la
  # detección automática (CatalogoGenerador.campos_indice_unico/1) por
  # una lista curada a mano, máximo 3, igual que Header.orden_resultados
  # (mismo tipo, mismo criterio de "[] = sin configurar, cae al
  # automático"). Ver FichaLive.llave_negocio/2 y
  # BcMotorLive.panel_llave_ficha/1.
  def change do
    alter table(:meta_schema_header) do
      add :campos_llave_ficha, {:array, :string}, default: [], null: false
    end
  end
end
