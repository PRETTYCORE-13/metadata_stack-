defmodule MetadataApp.Repo.Migrations.AgregarRenglonesAltaAConsultaEndpoint do
  use Ecto.Migration

  # SPEC-SYS-1009202602 (R59-R61, agregado 2026-09-14, a pedido
  # explícito -- "falta las filas del detalle") -- si el catálogo base
  # del endpoint es un MAESTRO (tiene catálogos detalle), el alta
  # (R54-R58) puede crear también los renglones iniciales en el MISMO
  # ciclo atómico, vía `CatalogoGenerico.crear/4` + `opciones[:renglones]`
  # (mecanismo YA existente, reusado tal cual -- ver Renglones.crear_todos/3).
  # `renglones_alta` -- [%{"catalogo" => "<catalogo_detalle>", "campos" => [...]}, ...],
  # mismo criterio de whitelist que `campos_alta` para el maestro.
  def change do
    alter table(:meta_schema_consulta_endpoint) do
      add :renglones_alta, {:array, :map}, default: [], null: false
    end
  end
end
