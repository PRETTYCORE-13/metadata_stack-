defmodule Mix.Tasks.Endpoint.Despublicar do
  use Mix.Task
  alias MetadataApp.ConsultaEndpoints
  alias MetadataApp.MetaConsultas

  @shortdoc "Lleva a un ambiente el borrado de un Endpoint ya eliminado en dev"

  @moduledoc """
  Uso: mix endpoint.despublicar --sistema=<sistema> <consulta>

  `--sistema=` obligatorio, sin default, mismo criterio que `mix
  motor.publicar`/`mix motor.despublicar` (SPEC-SYS-0309202601, R5/R10)
  -- se valida con `MetadataApp.MotorAlta.publicable?/1` antes de tocar
  nada: un cliente real de `priv/sistemas.json`, o `"unstable"` (nunca
  `"testing"`/`"stable"`).

  Contraparte de `mix motor.publicar` para un Endpoint que ya se borró
  LOCAL (sección Endpoints -> Eliminar, `ConsultaEndpoints.eliminar/1`)
  -- SPEC-SYS-1009202602, design.md §13, R71.

  A diferencia de `mix motor.despublicar` (para un catálogo real, que
  reusa la migración de DROP que deja `CatalogoGenerador.eliminar/4`),
  acá NO hay ninguna migración que reusar -- `ConsultaEndpoints.
  eliminar/1` es un `Repo.delete` directo sin generar nada en disco. Y
  a diferencia de un catálogo real, esta tarea NO puede reemplazar el
  release `bc-<consulta>` entero: adentro sigue viviendo la Consulta,
  que no se borró -- solo su Endpoint. Por eso el mecanismo es propio:
  escribe a mano el tombstone `<consulta>.endpoint.json` =
  `{"catalogo": "<consulta>", "eliminado": true}` y delega TODO lo
  demás en `mix motor.publicar` (que reconstruye el bundle completo de
  la Consulta con ese tombstone adentro, sin tocar nada más). `mix
  endpoint.export` -- que corre como parte de ESE `motor.publicar` --
  reconoce el tombstone y no lo borra ni lo regenera (ver su propio
  moduledoc).

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

    Mix.shell().info("== tombstone escrito para \"#{consulta_nombre}\" -- delegando en mix motor.publicar ==")
    Mix.Task.rerun("motor.publicar", ["--sistema=#{sistema}", consulta_nombre])
  end
end
