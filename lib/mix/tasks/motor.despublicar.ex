defmodule Mix.Tasks.Motor.Despublicar do
  use Mix.Task
  alias MetadataApp.MetaPublicador
  alias MetadataApp.BusinessProcessBuilder.MetaSchemaContext

  @shortdoc "Lleva a producción el borrado de un catálogo pty_* ya eliminado en dev"

  @moduledoc """
  Uso: mix motor.despublicar <catalogo>

  Contraparte de `mix motor.publicar` para el caso que ese task no cubre:
  un catálogo `pty_*` que ya se borró LOCAL (vía "Eliminar" en BC List,
  `CatalogoGenerador.eliminar/4`) nunca llega a producción por su cuenta
  -- ni por `commit`/`push` (`.gitignore` excluye todo `pty_*`, incluida
  su migración de DROP) ni por `mix motor.publicar` (exige que el catálogo
  SÍ exista para armar el paquete).

  Reutiliza `MetaPublicador.armar_bundle/1` tal cual: como el `.ex`, el
  `.meta.json`/`.motor.json` y la carpeta de reglas del catálogo ya no
  existen (se borraron junto con la tabla), el único archivo que
  `rutas_de/1` encuentra es la migración de DROP que `eliminar/4` dejó en
  `priv/repo/migrations/` -- el bundle queda armado solo con eso, sin
  código nuevo de empaquetado.

  Ese bundle reemplaza (`--clobber`) el Release `bc-<catalogo>` que dejó
  la publicación original -- CRÍTICO: `ci.yml` restaura TODOS los
  releases `bc-*` en cada deploy normal para no "olvidar" BCs publicados;
  sin reemplazar el bundle, el próximo deploy normal (push a main)
  resucitaría el catálogo borrado. Con el bundle reemplazado, ese mismo
  mecanismo trabaja a favor: cualquier deploy futuro (normal o disparado
  acá) vuelve a aplicar la migración de DROP (`drop_if_exists`, idempotente
  -- no-op si ya corrió) en vez de recrear el catálogo.
  """

  def run([]), do: Mix.raise("Uso: mix motor.despublicar <catalogo>")
  def run([_ | _] = varios) when length(varios) > 1, do: Mix.raise("Uso: mix motor.despublicar <catalogo> (uno solo por vez)")

  def run([catalogo]) do
    Mix.Task.run("app.config")

    {:ok, existe?, _apps} =
      Ecto.Migrator.with_repo(MetadataApp.Repo, fn _repo ->
        MetaSchemaContext.obtener_header_por_nombre(catalogo) != nil
      end)

    if existe? do
      Mix.raise(
        "\"#{catalogo}\" todavía existe en esta base -- despublicar es para un catálogo YA " <>
          "borrado local (BC List → Eliminar). Para publicar uno que SÍ existe, usá \"mix motor.publicar\"."
      )
    end

    migraciones = Path.wildcard("priv/repo/migrations/*_eliminar_#{catalogo}_*.exs")

    if migraciones == [] do
      Mix.raise(
        "No se encontró la migración de borrado de \"#{catalogo}\" en priv/repo/migrations/ -- " <>
          "¿ya lo borraste desde BC List → Eliminar?"
      )
    end

    Mix.shell().info("== armando bundle de borrado para #{catalogo} ==")
    Mix.shell().info("  migración: #{Enum.join(migraciones, ", ")}")

    armar_y_desplegar(catalogo)
  end

  defp armar_y_desplegar(catalogo) do
    case MetaPublicador.armar_bundle([catalogo]) do
      {:error, mensaje} ->
        Mix.raise(mensaje)

      {:ok, bundle_path} ->
        Mix.shell().info("  #{bundle_path} (#{MetaPublicador.tamanio_legible(bundle_path)})")
        Mix.shell().info("\n== reemplazando bc-#{catalogo} en GitHub Releases (el catálogo deja de resucitar en futuros deploys) ==")

        case MetaPublicador.persistir_bundle([catalogo], bundle_path) do
          {:error, mensaje} ->
            Mix.raise(mensaje)

          {:ok, tags} ->
            Mix.shell().info("  #{Enum.join(tags, ", ")}")
            Mix.shell().info("\n== disparando BC Deploy para aplicar el borrado en producción ahora ==")

            case MetaPublicador.disparar_deploy([catalogo], bundle_path) do
              {:ok, salida} ->
                Mix.shell().info(salida)
                Mix.shell().info("Disparado — el borrado de #{catalogo} va camino a producción. Seguí con \"gh run list\" / \"gh run watch\".")

              {:error, mensaje} ->
                Mix.raise(mensaje)
            end
        end
    end
  end
end
