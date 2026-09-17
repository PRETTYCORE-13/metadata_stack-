defmodule Mix.Tasks.Seed.Cargar do
  use Mix.Task
  alias MetadataApp.SeedMasterdata

  @shortdoc "Carga datos de prueba en catálogos pty_*/demo100_* (developer mode) -- SPEC-TEST-1509202601, Fase 2"

  @moduledoc """
  Uso:
    mix seed.cargar pty_mat_fabricante pty_dsd_linea
    mix seed.cargar --todos

  Crea, por cada catálogo, los registros descritos en su fixture
  (`priv/repo/seed_masterdata/<catalogo>.exs`, editable a mano —
  R9) pasando por el mismo camino real de alta que `POST /api/:tabla`
  (motor de estados, folio si aplica, reglas de negocio, TRN — R10).
  Nunca inserta filas directo en la tabla.

  Un campo tipo "referencia" se escribe en el fixture con el valor
  NATURAL del registro destino (ej. su descripción), nunca un id —
  se resuelve contra lo que YA está en la base al momento de crear
  ese registro (R11).

  Con nombres explícitos, el orden en que se escriben ES el orden de
  carga (mismo criterio que `seed.vaciar` — R3) y hace falta que
  TODOS tengan fixture, o corta con error. Con `--todos`, se cargan
  SOLO los catálogos de desarrollo que sí tienen fixture (no hace
  falta uno para cada catálogo que exista), en el orden que calcula
  `SeedMasterdata.orden_topologico/2 :carga` (dependencias primero —
  R12).

  TODA la corrida es atómica (R13): si UN registro falla (una regla
  de negocio lo rechaza, o una referencia no se encuentra), se
  deshacen TODOS los registros ya creados en esa misma corrida — el
  estado de los catálogos queda idéntico al que tenían antes de
  empezar, nunca parcialmente poblado.

  Mismos guardrails que `seed.vaciar`: nunca corre fuera de `:dev`
  (R6), nunca acepta un catálogo que no empiece con `pty_`/`demo100_`
  (R5).
  """

  def run(args) do
    if Mix.env() != :dev do
      Mix.raise("mix seed.cargar solo corre en :dev -- nunca en test ni producción.")
    end

    Mix.Task.run("app.config")

    {switches, nombres, _invalidos} = OptionParser.parse(args, strict: [todos: :boolean])
    todos? = switches[:todos] || false

    Ecto.Migrator.with_repo(MetadataApp.Repo, fn _repo ->
      ejecutar(nombres, todos?)
    end)
  end

  defp ejecutar(nombres, todos?) do
    with :ok <- validar_args(nombres, todos?),
         {:ok, orden} <- resolver_orden(nombres, todos?) do
      cargar(orden)
    else
      {:error, mensaje} -> Mix.raise(mensaje)
    end
  end

  defp validar_args(_nombres, true), do: :ok
  defp validar_args([], false), do: {:error, "Uso: mix seed.cargar <catalogo...> | --todos"}
  defp validar_args(_nombres, false), do: :ok

  # --todos: solo los que SÍ tienen fixture -- no hace falta uno para
  # cada catálogo de desarrollo que exista.
  defp resolver_orden(_nombres, true) do
    catalogos = SeedMasterdata.listar_catalogos_desarrollo() |> Enum.filter(&SeedMasterdata.fixture_existe?/1)

    if catalogos == [] do
      {:error, "Ningún catálogo de desarrollo tiene fixture en priv/repo/seed_masterdata/ -- nada que cargar."}
    else
      grafo = SeedMasterdata.grafo_dependencias(catalogos)

      case SeedMasterdata.orden_topologico(grafo, :carga) do
        {:ok, orden} ->
          {:ok, orden}

        {:error, :ciclo, involucrados} ->
          {:error,
           "Ciclo real de dependencias entre: #{Enum.join(involucrados, ", ")} -- no hay un orden " <>
             "automático posible (cargá por nombre explícito, en el orden que elijas)."}
      end
    end
  end

  # Nombres explícitos: mismo criterio que seed.vaciar -- el orden
  # escrito se respeta tal cual (R3), y TODOS tienen que ser válidos
  # (prefijo) Y tener fixture, o se corta el comando completo.
  defp resolver_orden(nombres, false) do
    invalidos_prefijo = Enum.reject(nombres, &(SeedMasterdata.validar_catalogo(&1) == :ok))
    sin_fixture = Enum.reject(nombres -- invalidos_prefijo, &SeedMasterdata.fixture_existe?/1)

    cond do
      invalidos_prefijo != [] ->
        {:error, "No son catálogos de desarrollo (prefijo pty_/demo100_): #{Enum.join(invalidos_prefijo, ", ")}"}

      sin_fixture != [] ->
        {:error, "Sin fixture en priv/repo/seed_masterdata/: #{Enum.join(sin_fixture, ", ")}"}

      true ->
        {:ok, nombres}
    end
  end

  defp cargar(orden) do
    Mix.shell().info("Se van a cargar, en este orden:\n" <> Enum.map_join(orden, "\n", &"  - #{&1}"))

    case SeedMasterdata.cargar(orden) do
      {:ok, creados} ->
        Mix.shell().info("\nListo -- #{length(creados)} registro(s) creado(s) vía alta real (TRN/folio/reglas aplicados).")

      {:error, mensaje} ->
        Mix.raise("Corrida deshecha por completo (nada quedó creado) -- #{mensaje}")
    end
  end
end
