defmodule MetadataAppWeb.FallbackController do
  use MetadataAppWeb, :controller
  require Logger

  def call(conn, {:error, %Ecto.Changeset{} = changeset}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{errors: MetadataApp.MetaErrores.traducir(changeset)})
  end

  def call(conn, {:error, :not_found}) do
    conn
    |> put_status(:not_found)
    |> json(%{errors: %{detail: "Registro no encontrado"}})
  end

  # --- RBAC (MetadataApp.Permissions) -------------------------------------

  def call(conn, {:error, :no_encontrado}) do
    conn
    |> put_status(:not_found)
    |> json(%{errors: %{detail: "Registro no encontrado"}})
  end

  def call(conn, {:error, :rol_de_sistema}) do
    conn
    |> put_status(:forbidden)
    |> json(%{errors: %{detail: "los roles de sistema no se editan ni se eliminan"}})
  end

  def call(conn, {:error, :rol_de_otra_empresa}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{errors: %{detail: "ese rol pertenece a otra empresa"}})
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

end
