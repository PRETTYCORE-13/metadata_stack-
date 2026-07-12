defmodule Mix.Tasks.Motor.Export do
  use Mix.Task
  alias MetadataApp.BusinessProcessBuilder.MetaSchemaContext
  alias MetadataApp.MetaEstadosAdmin

  @shortdoc "Exporta meta_schema_estados/transiciones/transicion_reglas a un JSON versionable"

  @moduledoc """
  Uso: mix motor.export [ruta_salida]

  Default: priv/repo/motor_export.json

  Vuelca el autómata (estados/transiciones/reglas) de cada Business Context
  que lo adoptó. Simétrico a `mix meta.export` (que cubre header+detalles,
  no el motor de estados) — resuelve toda referencia cruzada por NOMBRE, no
  por id, porque los ids autoincrementales no coinciden entre bases
  distintas (el mismo motivo por el que `meta.export`/`meta.import` usan
  `schema_context_name`).
  """

  def run(args) do
    Mix.Task.run("app.config")

    path = List.first(args) || "priv/repo/motor_export.json"

    {:ok, {contenido, total}, _apps} =
      Ecto.Migrator.with_repo(MetadataApp.Repo, fn _repo ->
        catalogos =
          MetaSchemaContext.listar_headers()
          |> Enum.map(&exportar_header/1)
          |> Enum.reject(&(&1.estados == []))

        contenido = Jason.encode!(%{catalogos: catalogos}, pretty: true)
        {contenido, length(catalogos)}
      end)

    File.write!(path, contenido)
    Mix.shell().info("Exportado el autómata de #{total} catálogo(s) a #{path}")
  end

  defp exportar_header(header) do
    estados = MetaEstadosAdmin.listar_estados(header.id)
    transiciones = MetaEstadosAdmin.listar_transiciones(header.id)
    nombres_por_id = Map.new(estados, &{&1.id, &1.nombre})

    %{
      catalogo: header.schema_context_name,
      estados: Enum.map(estados, &exportar_estado/1),
      transiciones: Enum.map(transiciones, &exportar_transicion(&1, nombres_por_id))
    }
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
      reglas: Enum.map(t.reglas, &exportar_regla/1)
    }
  end

  defp exportar_regla(r) do
    %{tipo: r.tipo, regla: r.regla, params: r.params, orden: r.orden, transaccional: r.transaccional}
  end
end
