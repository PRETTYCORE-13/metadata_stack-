defmodule Mix.Tasks.Seed.Reset do
  use Mix.Task

  @shortdoc "Reinicia y repuebla catálogos pty_*/demo100_* de prueba (developer mode) -- SPEC-TEST-1509202601, R14"

  @moduledoc """
  Uso:
    mix seed.reset pty_mat_fabricante pty_dsd_linea [--yes]
    mix seed.reset --todos [--yes]

  Encadena `mix seed.vaciar` y, solo si terminó bien, `mix seed.cargar`
  — mismo conjunto de catálogos en las dos fases (R14), pasando los
  mismos argumentos tal cual a los dos. Si `seed.vaciar` falla (ej.
  detecta un ciclo de dependencias, o un catálogo inválido), corta ahí
  — `seed.cargar` ni se intenta.

  Sin `--yes`, `seed.vaciar` pide confirmación UNA vez antes de tocar
  cualquier dato (`seed.cargar` nunca pide confirmación aparte, así
  que nunca hay una segunda). Con `--yes`, ninguna de las dos fases
  pregunta nada -- uso no interactivo.

  Mismos guardrails que los dos tasks que encadena (R5, R6) -- cada
  uno los revisa por su cuenta, sin duplicar la lógica acá.
  """

  def run(args) do
    Mix.Task.run("seed.vaciar", args)
    Mix.Task.run("seed.cargar", args)
  end
end
