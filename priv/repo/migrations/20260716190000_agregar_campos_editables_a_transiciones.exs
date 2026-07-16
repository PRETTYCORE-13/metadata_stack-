defmodule MetadataApp.Repo.Migrations.AgregarCamposEditablesATransiciones do
  use Ecto.Migration

  # Whitelist de schema_context_field que ESTA transición puede aceptar como
  # edición directa del caller (ver CatalogoGenerico.actualizar/2 +
  # MetaStateEngine.editar_con_transicion/3). Reemplaza la convención vieja
  # `editable_en` (lista de estado_id en meta_schema_detail.schema_context_properties):
  # esa vivía en el campo, indexada por estado, y solo servía para la única
  # transición "guardar" que el motor busca por nombre fijo. Acá vive en la
  # transición misma, así dos self-loops distintas desde el mismo estado
  # pueden tener whitelists distintos. Default '{}': una transición que no
  # edita nada (alta, dar_de_baja, reactivar) no declara ninguno.
  def change do
    alter table(:meta_schema_transiciones) do
      add :campos_editables, {:array, :string}, default: [], null: false
    end
  end
end
