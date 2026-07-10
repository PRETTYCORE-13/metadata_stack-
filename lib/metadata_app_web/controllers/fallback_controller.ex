defmodule MetadataAppWeb.FallbackController do
  use MetadataAppWeb, :controller
  require Logger

  def call(conn, {:error, %Ecto.Changeset{} = changeset}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{errors: traducir_errores(changeset)})
  end

  def call(conn, {:error, :not_found}) do
    conn
    |> put_status(:not_found)
    |> json(%{errors: %{detail: "Registro no encontrado"}})
  end

  # --- Desenlaces del ciclo de MetadataApp.MetaStateEngine.ejecutar_transicion/3
  # (spec sección 7, Contrato 2) ------------------------------------------

  # Paso 1: rechazo estructural — la acción no existe desde el estado actual.
  def call(conn, {:error, {:transicion_invalida, %{estado_actual_id: estado_id}}}) do
    conn
    |> put_status(:conflict)
    |> json(%{
      errors: %{detail: "transición inválida desde el estado actual", estado_actual_id: estado_id}
    })
  end

  # Paso 2: rechazo de negocio — información de proceso, no error de sistema.
  def call(conn, {:error, {:precondiciones, fallas}}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{errors: %{razones: fallas}})
  end

  # Paso 3: otro proceso ganó la carrera antes del commit.
  def call(conn, {:error, :conflicto_concurrencia}) do
    conn
    |> put_status(:conflict)
    |> json(%{errors: %{detail: "el registro cambió, recargue"}})
  end

  # Pasos 4-5a: falla de integridad. Error genérico al cliente — el detalle
  # real solo se loguea del lado del servidor, nada quedó persistido.
  def call(conn, {:error, {:postcondicion_fallida, razon}}) do
    Logger.error("StateEngine: postcondición transaccional falló: #{inspect(razon)}")

    conn
    |> put_status(:internal_server_error)
    |> json(%{errors: %{detail: "error interno, no se aplicó el cambio"}})
  end

  def call(conn, {:error, mensaje}) when is_binary(mensaje) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{errors: %{detail: mensaje}})
  end

  defp traducir_errores(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end
end
