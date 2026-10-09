defmodule Mix.Tasks.Meta.Huerfanos do
  @moduledoc """
  Limpieza de archivos "huérfanos" de las exportaciones completas
  (`mix meta.export`, `motor.export`, `plantillas.export` y
  `endpoint.export`), compartida por las cuatro (SPEC-SYS-0210202601, R6).

  Un huérfano es un archivo de `dir` con el `sufijo` de la tarea cuyo
  catálogo no existe en la base local. La carpeta es compartida: puede ser
  de otra persona o venir del repositorio. Por eso se listan y se pide
  confirmación; solo se borran con un "sí" explícito (un Enter vacío o
  sin entrada cuenta como "no").
  """

  @doc """
  `opts[:excluir]`: `fn archivo -> boolean end` para los que nunca son
  huérfanos (ej. la marca de baja de `mix endpoint.despublicar`).

  `:sin_huerfanos` | `{:borrados, archivos}` | `{:conservados, archivos}`.
  """
  def limpiar(dir, nombres_vigentes, sufijo, opts \\ []) do
    esperados = MapSet.new(nombres_vigentes, &"#{&1}#{sufijo}")
    excluir = Keyword.get(opts, :excluir, fn _archivo -> false end)

    huerfanos =
      dir
      |> File.ls!()
      |> Enum.filter(&String.ends_with?(&1, sufijo))
      |> Enum.reject(&MapSet.member?(esperados, &1))
      |> Enum.reject(excluir)
      |> Enum.sort()

    if huerfanos == [] do
      :sin_huerfanos
    else
      Mix.shell().info(
        "\n#{length(huerfanos)} archivo(s) #{sufijo} de catálogos que no existen en tu base local:"
      )

      Enum.each(huerfanos, &Mix.shell().info("  #{&1}"))

      pregunta = "¿Borrarlos? Pueden ser de otra persona o venir del repositorio."

      if Mix.shell().yes?(pregunta, default: :no) do
        Enum.each(huerfanos, fn archivo ->
          File.rm!(Path.join(dir, archivo))
          Mix.shell().info("  (huérfano borrado: #{archivo})")
        end)

        {:borrados, huerfanos}
      else
        Mix.shell().info("No se borró ninguno.")
        {:conservados, huerfanos}
      end
    end
  end
end
