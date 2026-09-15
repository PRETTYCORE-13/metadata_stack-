defmodule MetadataApp.Repo.Migrations.AgregarAltaAConsultaEndpoint do
  use Ecto.Migration

  # SPEC-SYS-1009202602 (R54-R58, agregado 2026-09-14, a pedido
  # explícito -- "necesito que el post agregue registros") -- un
  # endpoint POST puede, además de consultar, insertar un registro
  # nuevo en su catálogo base (mismas reglas que un alta manual desde
  # la UI, vía CatalogoGenerico.crear/4). `campos_alta` es el
  # whitelist explícito de campos reales del catálogo que el caller
  # externo puede mandar -- mismo criterio que `campos_permitidos` en
  # ConsultaEndpointCredencial para lectura.
  def change do
    alter table(:meta_schema_consulta_endpoint) do
      add :permite_alta, :boolean, default: false, null: false
      add :campos_alta, {:array, :string}, default: [], null: false
    end
  end
end
