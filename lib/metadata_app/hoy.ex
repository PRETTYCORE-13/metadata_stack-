defmodule MetadataApp.Hoy do
  @moduledoc """
  Fecha y hora "de hoy" de negocio, en la zona horaria del sistema
  (`config :metadata_app, :zona_horaria`, por omisión
  `America/Mexico_City`), no en UTC (SPEC-SYS-1109202601 R48). Después de
  las 18:00 de México, `Date.utc_today/0` ya da la fecha de mañana.

  Las marcas de auditoría (`inserted_at`, `fecha_registro` del sistema)
  siguen en UTC; esto es solo para valores que ve o captura el usuario.
  """

  @doc "Fecha local de hoy."
  def fecha, do: ahora() |> DateTime.to_date()

  @doc "Hora local actual, al segundo."
  def hora, do: ahora() |> DateTime.to_time() |> Time.truncate(:second)

  @doc "Momento local actual. `utc` permite probar con una hora fija."
  def ahora(utc \\ DateTime.utc_now()), do: DateTime.shift_zone!(utc, zona())

  @doc "Zona horaria configurada."
  def zona, do: Application.get_env(:metadata_app, :zona_horaria, "America/Mexico_City")
end
