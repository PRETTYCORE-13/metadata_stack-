defmodule Mix.Tasks.Meta.Plantillas.RegenerarAutomaticas do
  use Mix.Task

  @shortdoc "Reconstruye la \"Plantilla automática\" de todos los catálogos en el formato grid actual"

  @moduledoc """
  Uso: mix meta.plantillas.regenerar_automaticas

  Para catálogos generados ANTES de que el Constructor de PostViews pasara
  a ser un grid: su "Plantilla automática" sigue en el formato viejo
  (Sección con lista de campos). Este task la reconstruye con el formato
  actual (1 columna × N filas, ver `MetaPlantillas.regenerar_plantilla_automatica/1`)
  para todos los catálogos de una — un catálogo nuevo ya arranca así solo,
  esto es para ponerse al día con los que ya existían.

  Si un catálogo ya tiene una "Plantilla automática", solo se le refresca
  el CONTENIDO — nunca se toca qué plantilla está publicada ahora mismo
  (si esa era la publicada, sigue siéndolo; si no, sigue en borrador). Si
  un catálogo nunca tuvo una, se crea como borrador, sin publicarse sola
  — revisala en el Constructor y publicala vos si te gusta cómo quedó.

  Lógica real en `MetadataApp.MetaPlantillas.regenerar_todas_las_automaticas/0`.
  """

  def run(_args) do
    Mix.Task.run("app.config")

    {:ok, resultados, _apps} =
      Ecto.Migrator.with_repo(MetadataApp.Repo, fn _repo ->
        MetadataApp.MetaPlantillas.regenerar_todas_las_automaticas()
      end)

    Enum.each(resultados, fn
      {nombre, {:ok, _plantilla}} -> Mix.shell().info("✓ #{nombre}")
      {nombre, {:error, motivo}} -> Mix.shell().error("✗ #{nombre}: #{inspect(motivo)}")
    end)

    ok = Enum.count(resultados, &match?({_, {:ok, _}}, &1))
    Mix.shell().info("\n#{ok}/#{length(resultados)} catálogos regenerados.")
  end
end
