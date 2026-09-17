defmodule Mix.Tasks.Seed.Vaciar do
  use Mix.Task
  alias MetadataApp.SeedMasterdata
  alias MetadataApp.Repo

  @shortdoc "Vacía catálogos pty_*/demo100_* de prueba (developer mode) -- SPEC-TEST-1509202601, Fase 1"

  @moduledoc """
  Uso:
    mix seed.vaciar pty_mat_fabricante pty_dsd_linea [--yes]
    mix seed.vaciar --todos [--yes]

  Vacía por completo los catálogos nombrados (`DELETE` + reinicio de
  la secuencia de `id`, NO `TRUNCATE` -- ver el comentario de
  `vaciar_catalogo/1` para el motivo real) sin tocar su definición/
  configuración (campos, motor de estados, transiciones) — quedan
  listos para recibir datos nuevos sin reconfigurar nada (R1).

  Con nombres explícitos, el orden en que se escriben ES el orden de
  borrado — así se "edita" el orden sugerido (R3): la herramienta
  nunca lo reordena por su cuenta cuando el developer ya eligió uno.
  Con `--todos`, el orden lo calcula `SeedMasterdata.orden_topologico/2`
  a partir de las FKs reales entre los catálogos (R2) — quien
  referencia se vacía antes que a quien referencia, para no romper
  contra una FK todavía viva.

  `--yes` salta la confirmación interactiva (uso no interactivo, ej.
  desde un script propio) — sin ella, se imprime la lista final y se
  pide confirmar antes de tocar cualquier dato (R7).

  Nunca corre fuera de `:dev` (R6), y nunca acepta un catálogo que no
  empiece con `pty_`/`demo100_` (R5) — ambos guardrails se revisan
  ANTES de calcular nada, y cortan el comando COMPLETO ante el primer
  problema, no solo el catálogo que falló.
  """

  def run(args) do
    if Mix.env() != :dev do
      Mix.raise("mix seed.vaciar solo corre en :dev -- nunca en test ni producción.")
    end

    Mix.Task.run("app.config")

    {switches, nombres, _invalidos} = OptionParser.parse(args, strict: [todos: :boolean, yes: :boolean])
    todos? = switches[:todos] || false
    confirmado_de_antemano? = switches[:yes] || false

    Ecto.Migrator.with_repo(MetadataApp.Repo, fn _repo ->
      ejecutar(nombres, todos?, confirmado_de_antemano?)
    end)
  end

  defp ejecutar(nombres, todos?, confirmado_de_antemano?) do
    with :ok <- validar_args(nombres, todos?),
         {:ok, orden} <- resolver_orden(nombres, todos?),
         :ok <- validar_existencia(orden) do
      mostrar_y_ejecutar(orden, confirmado_de_antemano?)
    else
      {:error, mensaje} -> Mix.raise(mensaje)
    end
  end

  defp validar_args(_nombres, true), do: :ok
  defp validar_args([], false), do: {:error, "Uso: mix seed.vaciar <catalogo...> | --todos"}
  defp validar_args(_nombres, false), do: :ok

  # R5 + R6 (guardrail de nombre): se validan TODOS los nombres antes
  # de tocar cualquier cosa, y se reportan juntos -- un typo en el
  # tercer nombre no debería obligar a corregir de a uno.
  defp resolver_orden(_nombres, true) do
    catalogos = SeedMasterdata.listar_catalogos_desarrollo()
    grafo = SeedMasterdata.grafo_dependencias(catalogos)

    case SeedMasterdata.orden_topologico(grafo, :borrado) do
      {:ok, orden} ->
        {:ok, orden}

      {:error, :ciclo, involucrados} ->
        {:error,
         "Ciclo real de dependencias entre: #{Enum.join(involucrados, ", ")} -- no hay un orden " <>
           "automático posible, hay que resolverlo a mano (o vaciar por nombre explícito, en el orden que elijas)."}
    end
  end

  defp resolver_orden(nombres, false) do
    case Enum.reject(nombres, &(SeedMasterdata.validar_catalogo(&1) == :ok)) do
      [] -> {:ok, nombres}
      invalidos -> {:error, "No son catálogos de desarrollo (prefijo pty_/demo100_): #{Enum.join(invalidos, ", ")}"}
    end
  end

  # Typo real más probable que un ciclo de FK: mejor un error claro
  # acá que un TRUNCATE fallando por "relation does not exist" a
  # mitad de la lista, con los anteriores ya vaciados.
  defp validar_existencia(catalogos) do
    inexistentes = Enum.reject(catalogos, &tabla_existe?/1)

    if inexistentes == [] do
      :ok
    else
      {:error, "No existen como tabla: #{Enum.join(inexistentes, ", ")} -- revisá el nombre."}
    end
  end

  defp tabla_existe?(tabla) do
    %{rows: [[existe]]} = Repo.query!("SELECT to_regclass($1) IS NOT NULL", [tabla])
    existe
  end

  defp mostrar_y_ejecutar(orden, confirmado_de_antemano?) do
    Mix.shell().info("Se van a vaciar, en este orden:\n" <> Enum.map_join(orden, "\n", &"  - #{&1}"))

    if confirmado_de_antemano? or Mix.shell().yes?("\n¿Confirmás? Esto borra TODAS las filas, sin poder deshacerlo.") do
      Enum.each(orden, &vaciar_catalogo/1)
      Mix.shell().info("\nListo -- #{length(orden)} catálogo(s) vacío(s), estructura/motor de estados intactos.")
    else
      Mix.shell().info("Cancelado -- no se tocó nada.")
    end
  end

  # Bug real encontrado en vivo (2026-09-17): `TRUNCATE` en Postgres
  # rechaza vaciar una tabla si CUALQUIER OTRA tabla de la base entera
  # -- esté o no en la lista que se está vaciando -- tiene una FK real
  # apuntándole, sin importar el orden calculado ("cannot truncate a
  # table referenced in a foreign key constraint"). Pasó con
  # `pty_dsd_mat_lineas_sub`: `pty_dsd_mat_material` la referencia y
  # NO estaba en esta corrida -- el orden entre los 3 catálogos
  # elegidos era correcto, pero TRUNCATE igual la rechazó. `DELETE`
  # respeta el orden por FILA (si de verdad no hay ninguna fila
  # conflictiva afuera del conjunto, no hay problema) -- mismo
  # criterio que ya usa el resto de la app para borrados reales
  # (`CatalogoGenerador.eliminar/3`). Se reinicia la secuencia de
  # `id` aparte, a mano, para conservar R8 (numeración desde el
  # principio) sin las restricciones extra de TRUNCATE.
  defp vaciar_catalogo(tabla) do
    Repo.query!("DELETE FROM #{tabla}")
    reiniciar_secuencia(tabla)
    Mix.shell().info("  #{tabla}: vacío.")
  end

  defp reiniciar_secuencia(tabla) do
    case Repo.query!("SELECT pg_get_serial_sequence($1, 'id')", [tabla]) do
      %{rows: [[secuencia]]} when is_binary(secuencia) -> Repo.query!("ALTER SEQUENCE #{secuencia} RESTART WITH 1")
      _ -> :ok
    end
  end
end
