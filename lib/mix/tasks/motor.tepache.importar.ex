defmodule Mix.Tasks.Motor.Tepache.Importar do
  use Mix.Task
  alias MetadataApp.MetaTepache

  @shortdoc "Importa un tepache (bundle de otro desarrollador) en tu Postgres local, sin publicar nada"

  @moduledoc """
  Uso: mix motor.tepache.importar <TEPACHE-NNNNNN>

  Lado receptor de `mix motor.tepache`: baja el bundle de GitHub Releases,
  lo extrae sobre este proyecto, migra tu base local, e importa la
  metadata (catálogo(s) + autómata) — para que puedas revisarlo/probarlo
  en tu propia máquina sin que nadie haya publicado nada a producción
  todavía (ver docs/roadmap.md #14).

  La lógica vive en `MetadataApp.MetaTepache.preparar_import/1` +
  `aplicar_import/1` — compartida con la pantalla "Tepache Exp/Imp"
  (Business Process Builder), este task es solo la interfaz de línea de
  comandos. Si el catálogo YA existe localmente y el tepache no trae
  campos que tú sí tienes (se quitaron en el origen), este task PARA y
  pregunta antes de borrar nada — nunca elimina datos sin confirmación
  explícita.

  Registra automáticamente los permisos de cada catálogo importado
  (leer/crear/editar/eliminar + cada transición real), SIN concedérselos
  a ningún rol — si querés probarlo con un rol que no sea administrador,
  concedeselo vos desde Permission Sets, a propósito.

  Después de mirar/probar, si no lo querés dejar: usá la misma opción
  "Eliminar" de BC List sobre el catálogo importado.
  """

  def run([]), do: Mix.raise("Uso: mix motor.tepache.importar <TEPACHE-NNNNNN>")

  def run([tag]) do
    Mix.Task.run("app.config")

    Mix.shell().info("== bajando #{tag} ==")

    {:ok, preparado, _apps} =
      Ecto.Migrator.with_repo(MetadataApp.Repo, fn _repo -> MetaTepache.preparar_import(tag) end)

    case preparado do
      {:error, mensaje} ->
        Mix.raise(mensaje)

      {:ok, %{campos_removidos: campos_removidos} = info} ->
        if campos_removidos == %{} do
          aplicar(info)
        else
          avisar_y_confirmar(info)
        end
    end
  end

  defp avisar_y_confirmar(%{campos_removidos: campos_removidos} = info) do
    Mix.shell().info("\nEste tepache NO trae campos que tú sí tienes localmente (se habrían quitado en el origen):")

    Enum.each(campos_removidos, fn {nombre, campos} ->
      Mix.shell().info("  #{nombre}: #{Enum.join(campos, ", ")}")
    end)

    if Mix.shell().yes?("\n¿Confirmás eliminarlos (se pierden los datos de esas columnas)?") do
      aplicar(info)
    else
      Mix.shell().info("Cancelado — no se tocó nada.")
    end
  end

  defp aplicar(info) do
    Mix.shell().info("\n== extrayendo, migrando e importando ==")

    {:ok, resultado, _apps} =
      Ecto.Migrator.with_repo(MetadataApp.Repo, fn _repo -> MetaTepache.aplicar_import(info) end)

    case resultado do
      {:error, mensaje} ->
        Mix.raise(mensaje)

      {:ok, %{catalogos: catalogos, mensajes: mensajes}} ->
        Enum.each(mensajes, &Mix.shell().info("  #{&1}"))

        Mix.shell().info(
          "\nListo — #{Enum.join(catalogos, ", ")} ya está en tu Postgres local. " <>
            "Para probarlo con un rol puntual, concedeselo desde Permission Sets."
        )
    end
  end
end
