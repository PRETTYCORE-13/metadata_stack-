defmodule Mix.Tasks.Endpoint.Despublicar do
  use Mix.Task
  alias MetadataApp.ConsultaEndpoints
  alias MetadataApp.MetaConsultas
  alias MetadataApp.MetaPublicador

  @shortdoc "Lleva a un ambiente el borrado de un Endpoint ya eliminado en dev"

  @moduledoc """
  Uso: mix endpoint.despublicar --sistema=<sistema> <consulta>

  `--sistema=` obligatorio, sin default, mismo criterio que `mix
  motor.publicar`/`mix motor.despublicar` (SPEC-ARQ-0309202601, R5/R10)
  -- se valida con `MetadataApp.MotorAlta.publicable?/1` antes de tocar
  nada: un cliente real de `priv/sistemas.json`, o `"unstable"` (nunca
  `"testing"`/`"stable"`).

  Contraparte de `mix motor.publicar` para un Endpoint que ya se borró
  LOCAL (sección Endpoints -> Eliminar, `ConsultaEndpoints.eliminar/1`)
  -- SPEC-SYS-1009202602, design.md §13, R71.

  **Corregido dos veces sobre el diseño original (probado en vivo,
  2026-09-17):**
  1. No hay ninguna migración de DROP que reusar como sí hace `mix
     motor.despublicar` con un catálogo real -- `ConsultaEndpoints.
     eliminar/1` es un `Repo.delete` directo, sin generar nada en disco.
  2. NO se puede delegar en `mix motor.publicar` (primer intento): ese
     task arranca con `MetaPublicador.validar/1`, que EXIGE que el
     header exista -- y acá el header ya no existe (`eliminar/1` lo
     borra en cascada junto con la Consulta interna, el Endpoint y sus
     credenciales). Delegar ahí siempre fallaba con "no existe".

  El mecanismo real: escribe a mano el tombstone `<consulta>.endpoint.json`
  = `{"catalogo": "<consulta>", "eliminado": true}` y arma/sube/dispara el
  deploy con las funciones de bajo nivel de `MetaPublicador`
  directamente (`armar_bundle/1`, `persistir_bundle/2`,
  `disparar_deploy/3`) -- el MISMO patrón que ya usa `mix
  motor.despublicar` para un catálogo real. Reemplazar el release
  `bc-<consulta>` entero es seguro acá porque esta Consulta es la
  interna y descartable del propio Endpoint (nunca una Consulta de
  usuario reusada) -- no hay nada más que preservar bajo ese tag.

  `MetadataApp.MetaImportExport.importar_endpoint/1`, en destino, ve
  `"eliminado" => true` y hace `Repo.delete!` real del `ConsultaEndpoint`
  si existe -- no-op si ya no existía (idempotente, correrlo dos veces
  no es un error).
  """

  def run(args) do
    Mix.Task.run("app.config")

    {switches, nombres, _} = OptionParser.parse(args, strict: [sistema: :string])
    sistema = switches[:sistema]

    cond do
      is_nil(sistema) ->
        Mix.raise("Falta --sistema=<sistema>, obligatorio. Uso: mix endpoint.despublicar --sistema=<sistema> <consulta>")

      length(nombres) != 1 ->
        Mix.raise("Uso: mix endpoint.despublicar --sistema=<sistema> <consulta> (una sola Consulta por vez)")

      not MetadataApp.MotorAlta.publicable?(sistema) ->
        Mix.raise(
          "\"#{sistema}\" no está de alta (no aparece en priv/sistemas.json) ni es \"unstable\" -- no se puede despublicar ahí."
        )

      true ->
        despublicar(sistema, hd(nombres))
    end
  end

  defp despublicar(sistema, consulta_nombre) do
    {:ok, resultado, _apps} =
      Ecto.Migrator.with_repo(MetadataApp.Repo, fn _repo ->
        case MetaConsultas.obtener_por_catalogo(consulta_nombre) do
          # ConsultaEndpoints.eliminar/1 borra el Header ENTERO (cascada real
          # sobre Consulta/Endpoint/credenciales, ver design.md §13) -- que
          # ya no se encuentre acá es exactamente el estado esperado
          # DESPUÉS de "Eliminar" en la UI, no un error. Tratarlo como
          # error (versión anterior de este task) bloqueaba el flujo real
          # de despublicar justo en el caso para el que existe.
          nil -> :ok
          consulta -> if ConsultaEndpoints.obtener_por_consulta(consulta.id), do: :tiene_endpoint, else: :ok
        end
      end)

    case resultado do
      :tiene_endpoint ->
        Mix.raise(
          "\"#{consulta_nombre}\" todavía tiene un Endpoint vivo -- despublicar es para uno YA borrado " <>
            "local (sección Endpoints -> Eliminar). Para publicar el que existe, usá \"mix motor.publicar\"."
        )

      :ok ->
        escribir_tombstone_y_publicar(sistema, consulta_nombre)
    end
  end

  defp escribir_tombstone_y_publicar(sistema, consulta_nombre) do
    dir = "priv/repo/catalogos"
    File.mkdir_p!(dir)
    tombstone = Jason.encode!(%{catalogo: consulta_nombre, eliminado: true}, pretty: true)
    File.write!(Path.join(dir, "#{consulta_nombre}.endpoint.json"), tombstone)
    Mix.shell().info("== tombstone escrito para \"#{consulta_nombre}\" ==")

    case MetaPublicador.armar_bundle([consulta_nombre]) do
      {:error, mensaje} ->
        Mix.raise(mensaje)

      {:ok, bundle_path} ->
        Mix.shell().info("  #{bundle_path} (#{MetaPublicador.tamanio_legible(bundle_path)})")
        Mix.shell().info("\n== reemplazando bc-#{consulta_nombre} en GitHub Releases ==")

        case MetaPublicador.persistir_bundle([consulta_nombre], bundle_path) do
          {:error, mensaje} ->
            Mix.raise(mensaje)

          {:ok, tags} ->
            Mix.shell().info("  #{Enum.join(tags, ", ")}")
            Mix.shell().info("\n== disparando BC Deploy para aplicar el borrado en \"#{sistema}\" ==")

            case MetaPublicador.disparar_deploy(sistema, [consulta_nombre], bundle_path) do
              {:ok, salida} ->
                Mix.shell().info(salida)
                Mix.shell().info("Disparado -- el borrado de #{consulta_nombre} va camino a \"#{sistema}\". Seguí con \"gh run list\" / \"gh run watch\".")

              {:error, mensaje} ->
                Mix.raise(mensaje)
            end
        end
    end
  end
end
