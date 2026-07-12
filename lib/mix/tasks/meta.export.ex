defmodule Mix.Tasks.Meta.Export do
  use Mix.Task
  alias MetadataApp.BusinessProcessBuilder.MetaSchemaContext

  @shortdoc "Exporta meta_schema_header + meta_schema_detail a un archivo JSON por catálogo"

  @moduledoc """
  Uso: mix meta.export [directorio_salida]

  Default: priv/repo/catalogos/

  Un archivo `<catalogo>.meta.json` por Business Context activo (headers
  no borrados), con sus detalles. Reemplaza el export anterior de un solo
  `metadata_export.json` con todos los catálogos adentro: con muchos
  catálogos y varios desarrolladores tocando cada uno los suyos, un
  archivo único hacía que cualquier publicación reescribiera — y en el
  diff de git, aparentara tocar — TODOS los catálogos, no solo el que
  cambió.

  Sincroniza el directorio con el estado actual de la base: si un
  catálogo ya no existe (borrado total), su `.meta.json` huérfano se
  borra automáticamente.
  """

  def run(args) do
    Mix.Task.run("app.config")

    dir = List.first(args) || "priv/repo/catalogos"
    File.mkdir_p!(dir)

    {:ok, nombres, _apps} =
      Ecto.Migrator.with_repo(MetadataApp.Repo, fn _repo ->
        MetaSchemaContext.listar_headers()
        |> Enum.map(&exportar_header(&1, dir))
      end)

    limpiar_huerfanos(dir, nombres, ".meta.json")
    Mix.shell().info("Exportados #{length(nombres)} Business Context(s) a #{dir}/")
  end

  defp exportar_header(header, dir) do
    detalles = MetaSchemaContext.listar_detalles(header.schema_context_name)

    contenido =
      Jason.encode!(
        %{
          schema_context_name: header.schema_context_name,
          schema_context_label: header.schema_context_label,
          schema_context_type: header.schema_context_type,
          schema_context_nav: header.schema_context_nav,
          schema_visible: header.schema_visible,
          schema_set_permissions: header.schema_set_permissions,
          schema_profiles: header.schema_profiles,
          detalles: Enum.map(detalles, &MetaSchemaContext.serializar_detalle/1)
        },
        pretty: true
      )

    File.write!(Path.join(dir, "#{header.schema_context_name}.meta.json"), contenido)
    header.schema_context_name
  end

  # Sincroniza el directorio con lo que existe hoy en la base: un catálogo
  # que ya no está en `nombres_vigentes` (borrado total) no debe dejar un
  # archivo huérfano dando vueltas — se leería en el próximo import como si
  # todavía existiera.
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
