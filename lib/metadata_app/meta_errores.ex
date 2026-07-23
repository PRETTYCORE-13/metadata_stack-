defmodule MetadataApp.MetaErrores do
  @moduledoc """
  Traduce un Ecto.Changeset a %{campo => [mensajes]}, con los placeholders
  (%{count}, %{number}, etc.) ya interpolados — punto único para este
  patrón, antes duplicado (y con el mismo bug, ver formatear/1) en 6
  archivos: fallback_controller, catalogo_live, bc_list_live,
  bc_nuevo_completo_live, bc_motor_live.
  """

  @doc "Mapa %{campo => [mensajes]}, listo para un JSON de error o para recorrer a mano."
  def traducir(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {clave, valor}, acc ->
        String.replace(acc, "%{#{clave}}", formatear(valor))
      end)
    end)
  end

  @doc "Texto plano \"campo: mensaje; campo: mensaje\" para UI donde no hace falta el mapa estructurado."
  def resumen(changeset) do
    changeset
    |> traducir()
    |> Enum.map_join("; ", fn {campo, mensajes} -> "#{campo}: #{Enum.join(mensajes, ", ")}" end)
  end

  # Bug real corregido acá (2026-07-23): validate_inclusion manda una LISTA
  # en el opt :enum (los valores permitidos) — to_string/1 no implementa
  # String.Chars para List, así que interpolarla cruda tiraba
  # Protocol.UndefinedError en vez de mostrar el 422 de siempre (un campo
  # enum con un valor inválido tumbaba el request/la pantalla entera).
  # Cualquier valor no imprimible cae a inspect/1 en vez de crashear.
  defp formatear(valor) when is_binary(valor) or is_atom(valor) or is_number(valor), do: to_string(valor)
  defp formatear(valor), do: inspect(valor)
end
