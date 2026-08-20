defmodule MetadataApp.MetaErrores do
  @moduledoc """
  Traduce un Ecto.Changeset a %{campo => [mensajes]}, con los placeholders
  (%{count}, %{number}, etc.) ya interpolados — punto único para este
  patrón, antes duplicado (y con el mismo bug, ver formatear/1) en 6
  archivos: fallback_controller, catalogo_live, bc_list_live,
  bc_nuevo_completo_live, bc_motor_live.
  """

  alias MetadataApp.BusinessProcessBuilder.MetaSchemaContext

  @doc "Mapa %{campo => [mensajes]}, listo para un JSON de error o para recorrer a mano."
  def traducir(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {clave, valor}, acc ->
        String.replace(acc, "%{#{clave}}", formatear(valor))
      end)
    end)
  end

  @doc "Texto plano \"Etiqueta: mensaje; Etiqueta: mensaje\" para UI donde no hace falta el mapa estructurado."
  def resumen(changeset) do
    etiquetas = etiquetas_por_campo(changeset)

    changeset
    |> traducir()
    |> Enum.map_join("; ", fn {campo, mensajes} ->
      "#{Map.get(etiquetas, to_string(campo), to_string(campo))}: #{Enum.join(mensajes, ", ")}"
    end)
  end

  # `resumen/1` es la única versión pensada para pantalla (a diferencia de
  # `traducir/1`, que alimenta también respuestas JSON de la API — ahí sí
  # tiene que quedar el nombre físico del campo, no la etiqueta) — bug
  # real reportado: el banner de error mostraba
  # "pty_dsd_mat_material_precios_dsd_mat_precios_lista: no editable..."
  # en vez de "Listas de precios: no editable...". Sin catálogo resuelto
  # (source sin meta_schema_detail, ej. Header/Estado/Transicion) o campo
  # sin etiqueta propia (ej. "estado_id"), cae al nombre físico de
  # siempre — nunca rompe.
  defp etiquetas_por_campo(%Ecto.Changeset{data: %struct{}}) do
    struct.__schema__(:source)
    |> MetaSchemaContext.listar_detalles()
    |> Map.new(&{&1.schema_context_field, get_in(&1.schema_context_properties, ["etiqueta"]) || &1.schema_context_field})
  rescue
    _ -> %{}
  end

  defp etiquetas_por_campo(_changeset), do: %{}

  # Bug real corregido acá (2026-07-23): validate_inclusion manda una LISTA
  # en el opt :enum (los valores permitidos) — to_string/1 no implementa
  # String.Chars para List, así que interpolarla cruda tiraba
  # Protocol.UndefinedError en vez de mostrar el 422 de siempre (un campo
  # enum con un valor inválido tumbaba el request/la pantalla entera).
  # Cualquier valor no imprimible cae a inspect/1 en vez de crashear.
  defp formatear(valor) when is_binary(valor) or is_atom(valor) or is_number(valor), do: to_string(valor)
  defp formatear(valor), do: inspect(valor)
end
