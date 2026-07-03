defmodule MetadataAppWeb.FallbackController do
  use MetadataAppWeb, :controller

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
