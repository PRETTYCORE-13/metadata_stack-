defmodule Mix.Tasks.Motor.Export do
  use Mix.Task
  alias MetadataApp.BusinessProcessBuilder.MetaSchemaContext
  alias MetadataApp.MetaEstadosAdmin

  @shortdoc "Exporta el autómata (estados/transiciones/reglas) a un archivo JSON por catálogo"

  @moduledoc """
  Uso: mix motor.export [directorio_salida]

  Default: priv/repo/catalogos/ (mismo directorio que `mix meta.export`,
  sufijo distinto: `<catalogo>.motor.json`)

  Vuelca el autómata (estados/transiciones/reglas) de cada Business
  Context que lo adoptó — un archivo por catálogo, mismo motivo que
  `mix meta.export`: con muchos catálogos, un solo `motor_export.json`
  hacía que publicar UNO tocara el diff/merge de TODOS. Resuelve toda
  referencia cruzada por NOMBRE, no por id, porque los ids
  autoincrementales no coinciden entre bases distintas.

  Sincroniza el directorio: catálogos sin autómata (o borrados) no dejan
  un `.motor.json` huérfano.
  """

  def run(args) do
    Mix.Task.run("app.config")

    dir = List.first(args) || "priv/repo/catalogos"
    File.mkdir_p!(dir)

    {:ok, nombres, _apps} =
      Ecto.Migrator.with_repo(MetadataApp.Repo, fn _repo ->
        MetaSchemaContext.listar_headers()
        |> Enum.map(&exportar_header(&1, dir))
        |> Enum.reject(&is_nil/1)
      end)

    limpiar_huerfanos(dir, nombres, ".motor.json")
    Mix.shell().info("Exportado el autómata de #{length(nombres)} catálogo(s) a #{dir}/")
  end

  # nil si el catálogo no adoptó el motor (sin estados) — no le corresponde archivo.
  defp exportar_header(header, dir) do
    estados = MetaEstadosAdmin.listar_estados(header.id)

    if estados == [] do
      nil
    else
      transiciones = MetaEstadosAdmin.listar_transiciones(header.id)
      nombres_por_id = Map.new(estados, &{&1.id, &1.nombre})

      contenido =
        Jason.encode!(
          %{
            catalogo: header.schema_context_name,
            estados: Enum.map(estados, &exportar_estado/1),
            transiciones: Enum.map(transiciones, &exportar_transicion(&1, nombres_por_id))
          },
          pretty: true
        )

      File.write!(Path.join(dir, "#{header.schema_context_name}.motor.json"), contenido)
      header.schema_context_name
    end
  end

  defp exportar_estado(e) do
    %{
      nombre: e.nombre,
      orden: e.orden,
      es_inicial: e.es_inicial,
      color: e.color,
      icono: e.icono,
      empresa_id: e.empresa_id
    }
  end

  # estado_origen puede ser nil (transición de "alta" — el registro todavía
  # no existe, ver MetaSchema.Transicion).
  defp exportar_transicion(t, nombres_por_id) do
    %{
      accion: t.accion,
      etiqueta: t.etiqueta,
      empresa_id: t.empresa_id,
      estado_origen: t.estado_origen_id && Map.fetch!(nombres_por_id, t.estado_origen_id),
      estado_destino: Map.fetch!(nombres_por_id, t.estado_destino_id),
      campos_editables: t.campos_editables,
      reglas: Enum.map(t.reglas, &exportar_regla/1)
    }
  end

  defp exportar_regla(r) do
    %{tipo: r.tipo, regla: r.regla, params: r.params, orden: r.orden, transaccional: r.transaccional}
  end

  defp limpiar_huerfanos(dir, nombres_vigentes, sufijo) do
    esperados = MapSet.new(nombres_vigentes, &"#{&1}#{sufijo}")

    dir
    |> File.ls!()
    |> Enum.filter(&String.ends_with?(&1, sufijo))
    |> Enum.reject(&MapSet.member?(esperados, &1))
    |> Enum.each(fn archivo ->
      File.rm!(Path.join(dir, archivo))
      Mix.shell().info("  (huérfano borrado: #{archivo})")
    end)
  end
end
