defmodule Mix.Tasks.Motor.Reglas.Andamiar do
  use Mix.Task
  alias MetadataApp.BusinessProcessBuilder.MetaSchemaContext
  alias MetadataApp.MetaReglasCodigo

  @shortdoc "Genera (si no existen) el código PRE/POST de un catálogo, uno por tipo, con un case por transición real"

  @moduledoc """
  Uso: mix motor.reglas.andamiar <catalogo>

  Rediseño 2026-07-21: un catálogo tiene A LO SUMO un código pre y un
  código post — ya no un archivo por transición. Si el catálogo todavía no
  tiene código guardado para pre/post, genera un `case` con un branch por
  cada transición real (marcador `# ESCRIBA SU CODIGO AQUÍ` en cada uno) y
  lo guarda en `meta_schema_reglas_codigo`. Si ya existe código guardado,
  NUNCA lo pisa — hay que editarlo desde la UI (BcMotorLive, tab de
  reglas) o a mano.
  """

  def run([]), do: Mix.raise("Uso: mix motor.reglas.andamiar <catalogo>")

  def run([catalogo | _resto]) do
    Mix.Task.run("app.config")

    {:ok, resultado, _apps} =
      Ecto.Migrator.with_repo(MetadataApp.Repo, fn _repo -> andamiar(catalogo) end)

    case resultado do
      {:error, motivo} -> Mix.raise(motivo)
      :ok -> :ok
    end
  end

  defp andamiar(catalogo) do
    case MetaSchemaContext.obtener_header_por_nombre(catalogo) do
      nil ->
        {:error, "catálogo no encontrado: #{catalogo}"}

      header ->
        andamiar_tipo(header, "pre")
        andamiar_tipo(header, "post")
        :ok
    end
  end

  defp andamiar_tipo(header, tipo) do
    case MetaReglasCodigo.obtener_o_generar(header, tipo) do
      {:existente, _regla_codigo} ->
        Mix.shell().info("  = #{header.schema_context_name} (#{tipo}): ya tiene código guardado, sin tocar")

      {:nuevo, codigo_fuente} ->
        case MetaReglasCodigo.guardar(header, tipo, codigo_fuente, "mix motor.reglas.andamiar") do
          {:ok, _regla_codigo} ->
            Mix.shell().info("  + #{header.schema_context_name} (#{tipo}): stub generado y guardado")

          {:error, changeset} ->
            Mix.raise("no se pudo guardar #{tipo} de #{header.schema_context_name}: #{inspect(changeset.errors)}")
        end
    end
  end
end
